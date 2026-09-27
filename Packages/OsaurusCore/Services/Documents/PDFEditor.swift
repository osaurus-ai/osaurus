//
//  PDFEditor.swift
//  osaurus
//
//  PDF edits through PDFKit: delete / reorder / rotate pages, merge other
//  PDFs in, fill form fields, and add text boxes, notes, or highlights.
//  PDF body text isn't a flowing document, so rewriting it is refused
//  honestly with a pointer to editing the source (e.g. a .docx) instead.
//

import Foundation
import PDFKit

final class PDFEditor {
    let document: PDFDocument
    private(set) var summaries: [String] = []
    private(set) var warnings: [String] = []
    private let resolvePath: (String) throws -> URL

    static let operations = [
        "delete_pages", "reorder_pages", "rotate_pages", "merge", "fill_form", "add_text", "add_note", "highlight",
    ]

    init(data: Data, resolvePath: @escaping (String) throws -> URL) throws {
        guard let document = PDFDocument(data: data) else {
            throw DocumentEditError("The PDF couldn't be opened; it may be damaged.")
        }
        guard !document.isLocked, !document.isEncrypted || document.allowsDocumentChanges else {
            throw DocumentEditError("The PDF is password-protected or doesn't allow changes; it can't be edited.")
        }
        self.document = document
        self.resolvePath = resolvePath
    }

    var pageCount: Int { document.pageCount }

    func apply(_ op: DocumentOperation) throws {
        switch op.name {
        case "delete_pages": try deletePages(op)
        case "reorder_pages": try reorderPages(op)
        case "rotate_pages": try rotatePages(op)
        case "merge": try merge(op)
        case "fill_form": try fillForm(op)
        case "add_text": try addText(op)
        case "add_note": try addNote(op)
        case "highlight": try highlight(op)
        case "replace_text", "set_text", "edit_text":
            throw op.fail(
                "PDF body text can't be rewritten in place — a PDF stores positioned glyphs, not editable paragraphs. Edit the source document (e.g. the .docx) and export again, or regenerate the PDF with `file_write`. You can still add text boxes (`add_text`), notes, highlights, and fill form fields."
            )
        default:
            throw op.fail("unknown op for .pdf; use one of \(Self.operations.joined(separator: ", ")).")
        }
    }

    func data() throws -> Data {
        guard let data = document.dataRepresentation() else {
            throw DocumentEditError("PDFKit couldn't serialize the edited PDF.")
        }
        if hasSignatureField {
            warnings.append(
                "This PDF has a digital signature field; saving an edited copy invalidates any existing signatures. Keep the original if the signed version matters.")
        }
        warnings.append("The PDF was re-saved as a whole by PDFKit; earlier saved revisions embedded in the file aren't kept.")
        return data
    }

    /// Any `/Sig` widget, filled or not.
    private var hasSignatureField: Bool {
        widgets().contains { _, annotation in
            if annotation.widgetFieldType == .signature { return true }
            let fieldType = annotation.value(forAnnotationKey: .widgetFieldType) as? String
            return fieldType == "Sig" || fieldType == "/Sig"
        }
    }

    // MARK: - Pages

    private func pageIndices(_ op: DocumentOperation, key: String = "pages", defaultAll: Bool = false) throws -> [Int] {
        guard op.has(key) || op.has("page") else {
            if defaultAll { return Array(0..<pageCount) }
            throw op.fail("pass `\(key)` (page numbers from 1).")
        }
        var numbers = try op.optionalInts(key) ?? []
        if let single = try op.optionalInt("page") { numbers.append(single) }
        return try Array(Set(numbers)).sorted().map { try op.position($0, of: pageCount, noun: "page") }
    }

    private func deletePages(_ op: DocumentOperation) throws {
        let indices = try pageIndices(op)
        guard indices.count < pageCount else { throw op.fail("that would delete every page; keep at least one.") }
        for index in indices.reversed() { document.removePage(at: index) }
        summaries.append("Deleted page\(indices.count == 1 ? "" : "s") \(indices.map { String($0 + 1) }.joined(separator: ", "))")
    }

    private func reorderPages(_ op: DocumentOperation) throws {
        guard pageCount > 1 else { throw op.fail("there's only one page.") }
        let order = try op.permutation("order", count: pageCount, noun: "page")
        let pages = (0..<pageCount).compactMap { document.page(at: $0) }
        for index in (0..<pageCount).reversed() { document.removePage(at: index) }
        for (position, index) in order.enumerated() { document.insert(pages[index], at: position) }
        summaries.append("Reordered pages to \(order.map { String($0 + 1) }.joined(separator: ", "))")
    }

    private func rotatePages(_ op: DocumentOperation) throws {
        let degrees = try op.int("degrees")
        guard degrees % 90 == 0 else { throw op.fail("`degrees` must be a multiple of 90 (90, 180, 270, -90).") }
        let indices = try pageIndices(op, defaultAll: true)
        for index in indices {
            guard let page = document.page(at: index) else { continue }
            page.rotation = ((page.rotation + degrees) % 360 + 360) % 360
        }
        summaries.append("Rotated \(indices.count == pageCount ? "all pages" : "page\(indices.count == 1 ? "" : "s") \(indices.map { String($0 + 1) }.joined(separator: ", "))") by \(degrees)°")
    }

    private func merge(_ op: DocumentOperation) throws {
        var paths: [String] = []
        if let list = op.args["files"] as? [String] { paths = list }
        if let single = try op.optionalString("file") { paths.append(single) }
        guard !paths.isEmpty else { throw op.fail("pass `files`: PDF paths (relative to the working folder) to add.") }
        var insertAt = pageCount
        if let after = try op.optionalInt("after") {
            insertAt = after == 0 ? 0 : try op.position(after, of: pageCount, noun: "page") + 1
        }
        var added = 0
        for path in paths {
            let url = try resolvePath(path)
            guard let other = PDFDocument(url: url) else {
                throw op.fail("\"\(path)\" isn't a readable PDF.")
            }
            guard !other.isLocked else { throw op.fail("\"\(path)\" is password-protected.") }
            for index in 0..<other.pageCount {
                guard let page = other.page(at: index)?.copy() as? PDFPage else { continue }
                document.insert(page, at: insertAt)
                insertAt += 1
                added += 1
            }
        }
        summaries.append("Merged \(added) page\(added == 1 ? "" : "s") from \(paths.joined(separator: ", "))")
    }

    // MARK: - Forms

    private func widgets() -> [(page: Int, annotation: PDFAnnotation)] {
        var out: [(Int, PDFAnnotation)] = []
        for index in 0..<pageCount {
            for annotation in document.page(at: index)?.annotations ?? [] where annotation.type == "Widget" {
                out.append((index, annotation))
            }
        }
        return out
    }

    func formFields() -> [[String: Any]] {
        widgets().compactMap { page, annotation in
            guard let name = annotation.fieldName else { return nil }
            var field: [String: Any] = ["name": name, "page": page + 1]
            switch annotation.widgetFieldType {
            case .button:
                field["type"] = "checkbox"
                field["value"] = annotation.buttonWidgetState == .onState
            case .choice:
                field["type"] = "choice"
                field["value"] = annotation.widgetStringValue ?? ""
                if let options = annotation.choices { field["options"] = options }
            default:
                field["type"] = "text"
                field["value"] = annotation.widgetStringValue ?? ""
            }
            return field
        }
    }

    private func fillForm(_ op: DocumentOperation) throws {
        guard let fields = op.args["fields"] as? [String: Any], !fields.isEmpty else {
            throw op.fail("`fields` must map form field names to values, e.g. {\"Name\": \"Ada\", \"Agree\": true}.")
        }
        let all = widgets()
        guard !all.isEmpty else { throw op.fail("this PDF has no fillable form fields.") }
        let names = Set(all.compactMap { $0.annotation.fieldName })
        let unknown = fields.keys.filter { !names.contains($0) }
        guard unknown.isEmpty else {
            throw op.fail("no field named \(unknown.sorted().map { "\"\($0)\"" }.joined(separator: ", ")). Fields: \(names.sorted().prefix(40).joined(separator: ", ")).")
        }
        for (_, annotation) in all {
            guard let name = annotation.fieldName, let raw = fields[name] else { continue }
            switch annotation.widgetFieldType {
            case .button:
                let on: Bool
                switch raw {
                case let b as Bool: on = b
                case let s as String: on = ["true", "yes", "on", "1", "x", "checked"].contains(s.lowercased())
                case let n as NSNumber: on = n.boolValue
                default: on = false
                }
                annotation.buttonWidgetState = on ? .onState : .offState
            case .choice:
                let value = "\(raw)"
                if let options = annotation.choices, !options.isEmpty, !options.contains(value) {
                    throw op.fail("\"\(value)\" isn't an option for \"\(name)\". Options: \(options.joined(separator: ", ")).")
                }
                annotation.widgetStringValue = value
            default:
                annotation.widgetStringValue = raw is NSNull ? "" : "\(raw)"
            }
        }
        summaries.append("Filled \(fields.count) form field\(fields.count == 1 ? "" : "s")")
    }

    // MARK: - Annotations

    private func page(_ op: DocumentOperation) throws -> (Int, PDFPage) {
        let number = try op.int("page")
        let index = try op.position(number, of: pageCount, noun: "page")
        guard let page = document.page(at: index) else { throw op.fail("page \(number) couldn't be loaded.") }
        return (number, page)
    }

    private func addText(_ op: DocumentOperation) throws {
        let (number, page) = try page(op)
        let text = try op.string("text")
        let bounds = page.bounds(for: .cropBox)
        let size = CGFloat(try op.optionalInt("size") ?? 12)
        guard size >= 4, size <= 144 else { throw op.fail("`size` must be between 4 and 144 points.") }
        let font = NSFont.systemFont(ofSize: size)
        let lines = text.components(separatedBy: "\n")
        let longest = lines.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        let width = min(bounds.width - 20, max(40, longest + 12))
        let height = CGFloat(lines.count) * size * 1.3 + 8
        let x = CGFloat(try op.optionalInt("x") ?? 36) + bounds.minX
        let yTop = try op.optionalInt("y").map { bounds.minY + CGFloat($0) } ?? (bounds.maxY - 36)
        let rect = CGRect(x: x, y: yTop - height, width: width, height: height)
        guard bounds.insetBy(dx: -1, dy: -1).contains(rect) else {
            throw op.fail("the text box would fall outside page \(number) (\(Int(bounds.width))×\(Int(bounds.height)) pt; x/y are points from the bottom-left).")
        }
        let annotation = PDFAnnotation(bounds: rect, forType: .freeText, withProperties: nil)
        annotation.contents = text
        annotation.font = font
        annotation.fontColor = .black
        annotation.color = .clear
        page.addAnnotation(annotation)
        summaries.append("Added a text box on page \(number)")
    }

    private func addNote(_ op: DocumentOperation) throws {
        let (number, page) = try page(op)
        let text = try op.string("text")
        let bounds = page.bounds(for: .cropBox)
        let x = CGFloat(try op.optionalInt("x") ?? Int(bounds.width - 48)) + bounds.minX
        let y = CGFloat(try op.optionalInt("y") ?? Int(bounds.height - 48)) + bounds.minY
        let annotation = PDFAnnotation(bounds: CGRect(x: x, y: y, width: 20, height: 20), forType: .text, withProperties: nil)
        annotation.contents = text
        annotation.color = .systemYellow
        page.addAnnotation(annotation)
        summaries.append("Added a note on page \(number)")
    }

    private func highlight(_ op: DocumentOperation) throws {
        let find = try op.string("text")
        let restrict = try op.optionalInt("page")
        if let restrict { _ = try op.position(restrict, of: pageCount, noun: "page") }
        var count = 0
        for selection in document.findString(find, withOptions: [.caseInsensitive]) {
            for page in selection.pages {
                let index = document.index(for: page)
                if let restrict, index != restrict - 1 { continue }
                for line in selection.selectionsByLine() {
                    let rect = line.bounds(for: page)
                    guard rect.width > 0, rect.height > 0 else { continue }
                    let annotation = PDFAnnotation(bounds: rect, forType: .highlight, withProperties: nil)
                    annotation.color = NSColor.systemYellow.withAlphaComponent(0.5)
                    page.addAnnotation(annotation)
                }
                count += 1
            }
        }
        guard count > 0 else {
            throw op.fail("\"\(OOXMLText.preview(find, max: 60))\" wasn't found in the PDF's text layer (scanned pages have no text to highlight).")
        }
        summaries.append("Highlighted \(count) match\(count == 1 ? "" : "es") of \"\(OOXMLText.preview(find, max: 60))\"")
    }
}
