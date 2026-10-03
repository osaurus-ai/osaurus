//
//  PPTXEmitter.swift
//  osaurus
//
//  Writes a .pptx from Markdown: one slide per `#` / `##` heading (the
//  heading is the slide title, following lines are the body; `-` / `*`
//  lines become bullets, indented ones sub-bullets). A deck whose first
//  heading has no body besides a short line becomes a title slide.
//  Emits a minimal, complete package (theme, master, two layouts) with
//  no external template, so the output opens in PowerPoint and Keynote.
//

import Foundation

public struct PPTXEmitter: DocumentFormatEmitter {
    public let formatId = "pptx"

    public init() {}

    public func canEmit(_ document: StructuredDocument) -> Bool {
        (document.formatId == formatId || document.representation.formatId == formatId)
            && document.representation.underlying is RichTextSourceDocument
    }

    public func emit(_ document: StructuredDocument, to url: URL) async throws {
        guard let source = document.representation.underlying as? RichTextSourceDocument else {
            throw DocumentAdapterError.unsupportedFormat(formatId: document.formatId)
        }
        let slides = Self.slides(fromMarkdown: source.markup, fallbackTitle: source.title)
        do {
            try Self.packageData(slides: slides).write(to: url, options: .atomic)
        } catch let error as DocumentAdapterError {
            throw error
        } catch {
            throw DocumentAdapterError.writeFailed(underlying: error.localizedDescription)
        }
    }

    // MARK: - Outline

    struct Slide: Equatable {
        var title: String
        /// (indent level, text)
        var bullets: [(Int, String)]
        var isTitleSlide = false

        static func == (lhs: Slide, rhs: Slide) -> Bool {
            lhs.title == rhs.title && lhs.isTitleSlide == rhs.isTitleSlide
                && lhs.bullets.map(\.0) == rhs.bullets.map(\.0) && lhs.bullets.map(\.1) == rhs.bullets.map(\.1)
        }
    }

    static let maxSlides = 500

    static func slides(fromMarkdown markdown: String, fallbackTitle: String?) -> [Slide] {
        var slides: [Slide] = []
        var current: Slide?
        var inCode = false
        for raw in markdown.components(separatedBy: .newlines) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") { inCode.toggle(); continue }
            if !inCode, let heading = headingText(trimmed), heading.level <= 2 {
                if let current { slides.append(current) }
                current = Slide(title: plain(heading.text), bullets: [])
                continue
            }
            guard !trimmed.isEmpty else { continue }
            if current == nil { current = Slide(title: fallbackTitle ?? "", bullets: []) }
            if trimmed.hasPrefix("---") || trimmed.hasPrefix("|--") || trimmed.hasPrefix("| --") { continue }
            let indent = raw.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
            var level = min(4, indent / 2)
            var text = trimmed
            if let heading = headingText(trimmed) {
                text = heading.text
                level = 0
            } else if let marker = ["- ", "* ", "+ ", "• ", "•\t", "◦ ", "◦\t", "▪ ", "▪\t"].first(where: { trimmed.hasPrefix($0) }) {
                text = String(trimmed.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
            } else if let dot = trimmed.firstIndex(of: "."), trimmed[..<dot].allSatisfy(\.isNumber),
                !trimmed[..<dot].isEmpty, trimmed[trimmed.index(after: dot)...].hasPrefix(" ")
            {
                text = String(trimmed[trimmed.index(dot, offsetBy: 2)...])
            } else if trimmed.hasPrefix("|") {
                text = trimmed.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }.joined(separator: " · ")
            } else if trimmed.hasPrefix("> ") {
                text = String(trimmed.dropFirst(2))
            }
            current?.bullets.append((level, plain(text)))
        }
        if let current { slides.append(current) }
        if slides.isEmpty { slides = [Slide(title: fallbackTitle ?? "", bullets: [])] }
        if slides.count > 1, slides[0].bullets.count <= 1 {
            slides[0].isTitleSlide = true
        }
        return Array(slides.prefix(maxSlides))
    }

    private static func headingText(_ line: String) -> (level: Int, text: String)? {
        let hashes = line.prefix { $0 == "#" }.count
        guard hashes > 0, hashes <= 6, line.dropFirst(hashes).first == " " else { return nil }
        return (hashes, String(line.dropFirst(hashes + 1)).trimmingCharacters(in: .whitespaces))
    }

    /// Strip inline Markdown emphasis/code/link syntax.
    static func plain(_ text: String) -> String {
        var out = text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "`", with: "")
        if let regex = try? NSRegularExpression(pattern: "\\[([^\\]]*)\\]\\([^)]*\\)") {
            out = regex.stringByReplacingMatches(
                in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "$1")
        }
        if let regex = try? NSRegularExpression(pattern: "(?<![\\w*])\\*([^*]+)\\*(?![\\w*])") {
            out = regex.stringByReplacingMatches(
                in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "$1")
        }
        return out
    }

    // MARK: - Package

    private static let pNS = "http://schemas.openxmlformats.org/presentationml/2006/main"
    private static let aNS = "http://schemas.openxmlformats.org/drawingml/2006/main"
    private static let rNS = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    private static let relsNS = "http://schemas.openxmlformats.org/package/2006/relationships"
    private static let relBase = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/"
    private static let ctBase = "application/vnd.openxmlformats-officedocument.presentationml."
    private static let header = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"

    static func packageData(slides: [Slide]) throws -> Data {
        var writer = ZipArchiveWriter()
        func add(_ path: String, _ xml: String) throws {
            try writer.add(path: path, data: Data((header + xml).utf8))
        }
        let slideOverrides = slides.indices.map {
            "<Override PartName=\"/ppt/slides/slide\($0 + 1).xml\" ContentType=\"\(ctBase)slide+xml\"/>"
        }.joined()
        try add(
            "[Content_Types].xml",
            "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
                + "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>"
                + "<Default Extension=\"xml\" ContentType=\"application/xml\"/>"
                + "<Override PartName=\"/ppt/presentation.xml\" ContentType=\"\(ctBase)presentation.main+xml\"/>"
                + "<Override PartName=\"/ppt/slideMasters/slideMaster1.xml\" ContentType=\"\(ctBase)slideMaster+xml\"/>"
                + "<Override PartName=\"/ppt/slideLayouts/slideLayout1.xml\" ContentType=\"\(ctBase)slideLayout+xml\"/>"
                + "<Override PartName=\"/ppt/slideLayouts/slideLayout2.xml\" ContentType=\"\(ctBase)slideLayout+xml\"/>"
                + "<Override PartName=\"/ppt/theme/theme1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.theme+xml\"/>"
                + "<Override PartName=\"/ppt/presProps.xml\" ContentType=\"\(ctBase)presProps+xml\"/>"
                + "<Override PartName=\"/ppt/tableStyles.xml\" ContentType=\"\(ctBase)tableStyles+xml\"/>"
                + slideOverrides
                + "<Override PartName=\"/docProps/app.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.extended-properties+xml\"/>"
                + "</Types>")
        try add(
            "_rels/.rels",
            "<Relationships xmlns=\"\(relsNS)\">"
                + "<Relationship Id=\"rId1\" Type=\"\(relBase)officeDocument\" Target=\"ppt/presentation.xml\"/>"
                + "<Relationship Id=\"rId2\" Type=\"\(relBase)extended-properties\" Target=\"docProps/app.xml\"/>"
                + "</Relationships>")
        try add(
            "docProps/app.xml",
            "<Properties xmlns=\"http://schemas.openxmlformats.org/officeDocument/2006/extended-properties\">"
                + "<Application>Osaurus</Application><Slides>\(slides.count)</Slides></Properties>")

        let slideIds = slides.indices.map { "<p:sldId id=\"\(256 + $0)\" r:id=\"rId\(10 + $0)\"/>" }.joined()
        try add(
            "ppt/presentation.xml",
            "<p:presentation xmlns:a=\"\(aNS)\" xmlns:r=\"\(rNS)\" xmlns:p=\"\(pNS)\" saveSubsetFonts=\"1\">"
                + "<p:sldMasterIdLst><p:sldMasterId id=\"2147483648\" r:id=\"rId1\"/></p:sldMasterIdLst>"
                + "<p:sldIdLst>\(slideIds)</p:sldIdLst>"
                + "<p:sldSz cx=\"12192000\" cy=\"6858000\"/><p:notesSz cx=\"6858000\" cy=\"9144000\"/>"
                + "</p:presentation>")
        let slideRels = slides.indices.map {
            "<Relationship Id=\"rId\(10 + $0)\" Type=\"\(relBase)slide\" Target=\"slides/slide\($0 + 1).xml\"/>"
        }.joined()
        try add(
            "ppt/_rels/presentation.xml.rels",
            "<Relationships xmlns=\"\(relsNS)\">"
                + "<Relationship Id=\"rId1\" Type=\"\(relBase)slideMaster\" Target=\"slideMasters/slideMaster1.xml\"/>"
                + "<Relationship Id=\"rId2\" Type=\"\(relBase)theme\" Target=\"theme/theme1.xml\"/>"
                + "<Relationship Id=\"rId3\" Type=\"\(relBase)presProps\" Target=\"presProps.xml\"/>"
                + "<Relationship Id=\"rId4\" Type=\"\(relBase)tableStyles\" Target=\"tableStyles.xml\"/>"
                + slideRels
                + "</Relationships>")
        try add("ppt/presProps.xml", "<p:presentationPr xmlns:a=\"\(aNS)\" xmlns:r=\"\(rNS)\" xmlns:p=\"\(pNS)\"/>")
        try add("ppt/tableStyles.xml", "<a:tblStyleLst xmlns:a=\"\(aNS)\" def=\"{5C22544A-7EE6-4342-B048-85BDC9FD1C3A}\"/>")
        try add("ppt/theme/theme1.xml", themeXML)
        try add("ppt/slideMasters/slideMaster1.xml", masterXML)
        try add(
            "ppt/slideMasters/_rels/slideMaster1.xml.rels",
            "<Relationships xmlns=\"\(relsNS)\">"
                + "<Relationship Id=\"rId1\" Type=\"\(relBase)slideLayout\" Target=\"../slideLayouts/slideLayout1.xml\"/>"
                + "<Relationship Id=\"rId2\" Type=\"\(relBase)slideLayout\" Target=\"../slideLayouts/slideLayout2.xml\"/>"
                + "<Relationship Id=\"rId3\" Type=\"\(relBase)theme\" Target=\"../theme/theme1.xml\"/>"
                + "</Relationships>")
        let layoutRels =
            "<Relationships xmlns=\"\(relsNS)\"><Relationship Id=\"rId1\" Type=\"\(relBase)slideMaster\" Target=\"../slideMasters/slideMaster1.xml\"/></Relationships>"
        try add("ppt/slideLayouts/slideLayout1.xml", layoutXML(type: "title", name: "Title Slide", titleType: "ctrTitle", bodyType: "subTitle"))
        try add("ppt/slideLayouts/_rels/slideLayout1.xml.rels", layoutRels)
        try add("ppt/slideLayouts/slideLayout2.xml", layoutXML(type: "obj", name: "Title and Content", titleType: "title", bodyType: nil))
        try add("ppt/slideLayouts/_rels/slideLayout2.xml.rels", layoutRels)

        for (index, slide) in slides.enumerated() {
            try add("ppt/slides/slide\(index + 1).xml", slideXML(slide))
            try add(
                "ppt/slides/_rels/slide\(index + 1).xml.rels",
                "<Relationships xmlns=\"\(relsNS)\"><Relationship Id=\"rId1\" Type=\"\(relBase)slideLayout\" Target=\"../slideLayouts/slideLayout\(slide.isTitleSlide ? 1 : 2).xml\"/></Relationships>"
            )
        }
        do {
            return try writer.finalize()
        } catch {
            throw DocumentAdapterError.writeFailed(underlying: error.localizedDescription)
        }
    }

    private static func escape(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "\t": out += " "
            default:
                // XML 1.0 forbids most C0 controls (shared rule with the editors).
                if OOXMLText.isInvalidXML(scalar) { continue }
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    private static let emptyGroup =
        "<p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>"
        + "<p:grpSpPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"0\" cy=\"0\"/><a:chOff x=\"0\" y=\"0\"/><a:chExt cx=\"0\" cy=\"0\"/></a:xfrm></p:grpSpPr>"

    private static func placeholder(
        id: Int, name: String, type: String?, idx: Int?, frame: (Int, Int, Int, Int)?, paragraphs: String
    ) -> String {
        var ph = "<p:ph"
        if let type { ph += " type=\"\(type)\"" }
        if let idx { ph += " idx=\"\(idx)\"" }
        ph += "/>"
        let xfrm = frame.map { "<a:xfrm><a:off x=\"\($0.0)\" y=\"\($0.1)\"/><a:ext cx=\"\($0.2)\" cy=\"\($0.3)\"/></a:xfrm>" } ?? ""
        return "<p:sp><p:nvSpPr><p:cNvPr id=\"\(id)\" name=\"\(name)\"/><p:cNvSpPr><a:spLocks noGrp=\"1\"/></p:cNvSpPr><p:nvPr>\(ph)</p:nvPr></p:nvSpPr>"
            + "<p:spPr>\(xfrm)</p:spPr><p:txBody><a:bodyPr/><a:lstStyle/>\(paragraphs)</p:txBody></p:sp>"
    }

    private static func slideXML(_ slide: Slide) -> String {
        let title = "<a:p><a:r><a:rPr lang=\"en-US\" dirty=\"0\"/><a:t>\(escape(slide.title))</a:t></a:r></a:p>"
        let bodyParagraphs =
            slide.bullets.isEmpty
            ? "<a:p><a:endParaRPr lang=\"en-US\" dirty=\"0\"/></a:p>"
            : slide.bullets.map { level, text in
                let pPr = level > 0 ? "<a:pPr lvl=\"\(level)\"/>" : ""
                return "<a:p>\(pPr)<a:r><a:rPr lang=\"en-US\" dirty=\"0\"/><a:t>\(escape(text))</a:t></a:r></a:p>"
            }.joined()
        let shapes: String
        if slide.isTitleSlide {
            shapes =
                placeholder(id: 2, name: "Title 1", type: "ctrTitle", idx: nil, frame: nil, paragraphs: title)
                + placeholder(id: 3, name: "Subtitle 2", type: "subTitle", idx: 1, frame: nil, paragraphs: bodyParagraphs)
        } else {
            shapes =
                placeholder(id: 2, name: "Title 1", type: "title", idx: nil, frame: nil, paragraphs: title)
                + placeholder(id: 3, name: "Content Placeholder 2", type: nil, idx: 1, frame: nil, paragraphs: bodyParagraphs)
        }
        return "<p:sld xmlns:a=\"\(aNS)\" xmlns:r=\"\(rNS)\" xmlns:p=\"\(pNS)\"><p:cSld><p:spTree>\(emptyGroup)\(shapes)</p:spTree></p:cSld>"
            + "<p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>"
    }

    private static func layoutXML(type: String, name: String, titleType: String, bodyType: String?) -> String {
        let empty = "<a:p><a:endParaRPr lang=\"en-US\"/></a:p>"
        let titleFrame = type == "title" ? (1524000, 1122363, 9144000, 2387600) : (838200, 365125, 10515600, 1325563)
        let bodyFrame = type == "title" ? (1524000, 3602038, 9144000, 1655762) : (838200, 1825625, 10515600, 4351338)
        let shapes =
            placeholder(id: 2, name: "Title 1", type: titleType, idx: nil, frame: titleFrame, paragraphs: empty)
            + placeholder(id: 3, name: bodyType == nil ? "Content Placeholder 2" : "Subtitle 2", type: bodyType, idx: 1, frame: bodyFrame, paragraphs: empty)
        return "<p:sldLayout xmlns:a=\"\(aNS)\" xmlns:r=\"\(rNS)\" xmlns:p=\"\(pNS)\" type=\"\(type)\" preserve=\"1\">"
            + "<p:cSld name=\"\(name)\"><p:spTree>\(emptyGroup)\(shapes)</p:spTree></p:cSld>"
            + "<p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>"
    }

    private static var masterXML: String {
        let empty = "<a:p><a:endParaRPr lang=\"en-US\"/></a:p>"
        let shapes =
            placeholder(id: 2, name: "Title Placeholder 1", type: "title", idx: nil, frame: (838200, 365125, 10515600, 1325563), paragraphs: empty)
            + placeholder(id: 3, name: "Text Placeholder 2", type: "body", idx: 1, frame: (838200, 1825625, 10515600, 4351338), paragraphs: empty)
        func level(_ n: Int, size: Int) -> String {
            let margin = 228600 + n * 457200
            return "<a:lvl\(n + 1)pPr marL=\"\(margin)\" indent=\"-228600\" algn=\"l\"><a:lnSpc><a:spcPct val=\"90000\"/></a:lnSpc>"
                + "<a:spcBef><a:spcPts val=\"\(n == 0 ? 1000 : 500)\"/></a:spcBef><a:buFont typeface=\"Arial\"/><a:buChar char=\"•\"/>"
                + "<a:defRPr sz=\"\(size)\" kern=\"1200\"><a:solidFill><a:schemeClr val=\"tx1\"/></a:solidFill><a:latin typeface=\"+mn-lt\"/><a:ea typeface=\"+mn-ea\"/><a:cs typeface=\"+mn-cs\"/></a:defRPr></a:lvl\(n + 1)pPr>"
        }
        let bodyLevels = [2800, 2400, 2000, 1800, 1800].enumerated().map { level($0.offset, size: $0.element) }.joined()
        return "<p:sldMaster xmlns:a=\"\(aNS)\" xmlns:r=\"\(rNS)\" xmlns:p=\"\(pNS)\">"
            + "<p:cSld><p:bg><p:bgRef idx=\"1001\"><a:schemeClr val=\"bg1\"/></p:bgRef></p:bg><p:spTree>\(emptyGroup)\(shapes)</p:spTree></p:cSld>"
            + "<p:clrMap bg1=\"lt1\" tx1=\"dk1\" bg2=\"lt2\" tx2=\"dk2\" accent1=\"accent1\" accent2=\"accent2\" accent3=\"accent3\" accent4=\"accent4\" accent5=\"accent5\" accent6=\"accent6\" hlink=\"hlink\" folHlink=\"folHlink\"/>"
            + "<p:sldLayoutIdLst><p:sldLayoutId id=\"2147483649\" r:id=\"rId1\"/><p:sldLayoutId id=\"2147483650\" r:id=\"rId2\"/></p:sldLayoutIdLst>"
            + "<p:txStyles>"
            + "<p:titleStyle><a:lvl1pPr algn=\"l\"><a:lnSpc><a:spcPct val=\"90000\"/></a:lnSpc><a:buNone/><a:defRPr sz=\"4400\" kern=\"1200\"><a:solidFill><a:schemeClr val=\"tx1\"/></a:solidFill><a:latin typeface=\"+mj-lt\"/><a:ea typeface=\"+mj-ea\"/><a:cs typeface=\"+mj-cs\"/></a:defRPr></a:lvl1pPr></p:titleStyle>"
            + "<p:bodyStyle>\(bodyLevels)</p:bodyStyle>"
            + "<p:otherStyle><a:lvl1pPr><a:defRPr sz=\"1800\" kern=\"1200\"><a:solidFill><a:schemeClr val=\"tx1\"/></a:solidFill><a:latin typeface=\"+mn-lt\"/></a:defRPr></a:lvl1pPr></p:otherStyle>"
            + "</p:txStyles></p:sldMaster>"
    }

    private static var themeXML: String {
        func srgb(_ hex: String) -> String { "<a:srgbClr val=\"\(hex)\"/>" }
        let colors =
            "<a:dk1><a:sysClr val=\"windowText\" lastClr=\"000000\"/></a:dk1><a:lt1><a:sysClr val=\"window\" lastClr=\"FFFFFF\"/></a:lt1>"
            + "<a:dk2>\(srgb("44546A"))</a:dk2><a:lt2>\(srgb("E7E6E6"))</a:lt2>"
            + "<a:accent1>\(srgb("4472C4"))</a:accent1><a:accent2>\(srgb("ED7D31"))</a:accent2><a:accent3>\(srgb("A5A5A5"))</a:accent3>"
            + "<a:accent4>\(srgb("FFC000"))</a:accent4><a:accent5>\(srgb("5B9BD5"))</a:accent5><a:accent6>\(srgb("70AD47"))</a:accent6>"
            + "<a:hlink>\(srgb("0563C1"))</a:hlink><a:folHlink>\(srgb("954F72"))</a:folHlink>"
        let fonts =
            "<a:majorFont><a:latin typeface=\"Calibri Light\"/><a:ea typeface=\"\"/><a:cs typeface=\"\"/></a:majorFont>"
            + "<a:minorFont><a:latin typeface=\"Calibri\"/><a:ea typeface=\"\"/><a:cs typeface=\"\"/></a:minorFont>"
        let solid = "<a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill>"
        let line = "<a:ln w=\"6350\" cap=\"flat\" cmpd=\"sng\" algn=\"ctr\">\(solid)<a:prstDash val=\"solid\"/><a:miter lim=\"800000\"/></a:ln>"
        let format =
            "<a:fillStyleLst>\(solid)\(solid)\(solid)</a:fillStyleLst>"
            + "<a:lnStyleLst>\(line)\(line)\(line)</a:lnStyleLst>"
            + "<a:effectStyleLst><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle></a:effectStyleLst>"
            + "<a:bgFillStyleLst>\(solid)\(solid)\(solid)</a:bgFillStyleLst>"
        return "<a:theme xmlns:a=\"\(aNS)\" name=\"Osaurus\"><a:themeElements>"
            + "<a:clrScheme name=\"Osaurus\">\(colors)</a:clrScheme>"
            + "<a:fontScheme name=\"Osaurus\">\(fonts)</a:fontScheme>"
            + "<a:fmtScheme name=\"Osaurus\">\(format)</a:fmtScheme>"
            + "</a:themeElements><a:objectDefaults/><a:extraClrSchemeLst/></a:theme>"
    }
}
