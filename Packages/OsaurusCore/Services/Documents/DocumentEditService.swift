//
//  DocumentEditService.swift
//  osaurus
//
//  In-place edits of .docx / .xlsx / .pptx / .pdf for `file_edit`, and the
//  addressable outline `file_read` structure mode returns. Every edit is
//  validate-then-swap: the result is written to a hidden temp file beside
//  the original, re-opened with our own document adapter (and PDFKit for
//  PDFs), and only then atomically swapped in — and only if the original
//  hasn't changed meanwhile. A failed edit never touches the original.
//

import Foundation
import PDFKit

enum DocumentEditService {
    static let editableExtensions: Set<String> = ["docx", "xlsx", "pptx", "pdf"]
    static let maxFileBytes = 200 * 1024 * 1024
    static let maxOperations = 50

    static func isEditable(_ ext: String) -> Bool { editableExtensions.contains(ext.lowercased()) }

    static func operationNames(for ext: String) -> [String] {
        switch ext.lowercased() {
        case "docx": return DOCXEditor.operations
        case "xlsx": return XLSXEditor.operations
        case "pptx": return PPTXEditor.operations
        case "pdf": return PDFEditor.operations
        default: return []
        }
    }

    static let allOperationNames: [String] = Array(
        Set(DOCXEditor.operations + XLSXEditor.operations + PPTXEditor.operations + PDFEditor.operations)
    ).sorted()

    /// Schema for one `operations[]` entry: a free-form object whose keys are
    /// documented in the `operations` description, NOT enumerated as
    /// `properties`. Declaring the per-operation keys breaks
    /// schema-constrained decoders: with `properties` present, xAI's
    /// grok-4.3 deterministically emitted `{"op": "replace_text", "slide": 1,
    /// "text": "Lisbon", "x": 0, "y": 0}` and never `old_string`/`new_string`
    /// (probe: /tmp xai_probe, 3/3 runs), and the original `{op}`-only
    /// declaration arrived as `{"op": "replace_text"}` with every other key
    /// dropped. The same request against `{"type": "object"}` produced the
    /// correct `old_string`/`new_string`/`slide` 3/3. Every editor validates
    /// its own keys with entry-numbered errors, so nothing is lost locally.
    static let operationItemSchema: JSONValue = .object([
        "type": .string("object"),
        "description": .string(
            "One operation: {\"op\": name, …keys for that op}. `op` is one of: "
                + allOperationNames.joined(separator: ", ")
                + ". replace_text needs old_string + new_string; set_cells needs cells; fill_form needs fields; "
                + "insert_paragraph needs text (+ after|before); set_slide_text needs slide + shape + text."
        ),
    ])

    /// An applied, validated edit waiting to be committed or discarded.
    final class PreparedEdit {
        let fileURL: URL
        let tempURL: URL
        let originalData: Data
        let summaries: [String]
        let warnings: [String]
        let diffText: String?
        let diffTruncated: Bool
        private var finished = false

        init(
            fileURL: URL, tempURL: URL, originalData: Data, summaries: [String], warnings: [String],
            diffText: String?, diffTruncated: Bool
        ) {
            self.fileURL = fileURL
            self.tempURL = tempURL
            self.originalData = originalData
            self.summaries = summaries
            self.warnings = warnings
            self.diffText = diffText
            self.diffTruncated = diffTruncated
        }

        deinit { if !finished { try? FileManager.default.removeItem(at: tempURL) } }

        func discard() {
            finished = true
            try? FileManager.default.removeItem(at: tempURL)
        }

        /// Swap the validated result in, unless the original changed since
        /// it was read (another app saved it) — then nothing is written.
        func commit() throws {
            defer {
                finished = true
                try? FileManager.default.removeItem(at: tempURL)
            }
            guard let current = try? Data(contentsOf: fileURL), current == originalData else {
                throw DocumentEditError(
                    "'\(fileURL.lastPathComponent)' changed while it was being edited (is it open in another app?). Nothing was written; read it again and retry."
                )
            }
            if let permissions = try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.posixPermissions] {
                try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: tempURL.path)
            }
            do {
                _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tempURL)
            } catch {
                throw DocumentEditError("Couldn't save '\(fileURL.lastPathComponent)': \(error.localizedDescription). The original is unchanged.")
            }
        }
    }

    // MARK: - Edit

    static func prepare(
        fileURL: URL,
        displayPath: String,
        operations rawOperations: [[String: Any]],
        resolvePath: @escaping (String) throws -> URL
    ) async throws -> PreparedEdit {
        let ext = fileURL.pathExtension.lowercased()
        guard isEditable(ext) else {
            throw DocumentEditError(".\(ext) files can't be edited with `operations`; only .docx, .xlsx, .pptx and .pdf.")
        }
        guard !rawOperations.isEmpty else { throw DocumentEditError("`operations` is empty.") }
        guard rawOperations.count <= maxOperations else {
            throw DocumentEditError("\(rawOperations.count) operations is over the \(maxOperations)-per-call limit; split them up.")
        }
        let allowed = operationNames(for: ext)
        let operations = try rawOperations.enumerated().map {
            try DocumentOperation(index: $0.offset, raw: $0.element, allowed: allowed)
        }

        let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maxFileBytes else {
            throw DocumentEditError("'\(displayPath)' is \(size / 1_048_576) MB; documents over \(maxFileBytes / 1_048_576) MB aren't edited in place.")
        }
        let original: Data
        do {
            original = try Data(contentsOf: fileURL)
        } catch {
            throw DocumentEditError("Couldn't read '\(displayPath)': \(error.localizedDescription)")
        }

        let edited: Data
        var summaries: [String] = []
        var warnings: [String] = []
        switch ext {
        case "pdf":
            let editor = try PDFEditor(data: original, resolvePath: resolvePath)
            for op in operations { try editor.apply(op) }
            edited = try editor.data()
            summaries = editor.summaries
            warnings = editor.warnings
        default:
            let package = try OOXMLPackage(data: original)
            switch ext {
            case "docx":
                var editor = try DOCXEditor(package: package)
                for op in operations { try editor.apply(op) }
                summaries = editor.summaries
                warnings = editor.warnings
            case "xlsx":
                var editor = try XLSXEditor(package: package)
                for op in operations { try editor.apply(op) }
                try editor.finish()
                summaries = editor.summaries
                warnings = editor.warnings
            default:
                var editor = try PPTXEditor(package: package)
                for op in operations { try editor.apply(op) }
                summaries = editor.summaries
                warnings = editor.warnings
            }
            edited = try package.serialize()
        }

        let stem = fileURL.deletingPathExtension().lastPathComponent
        let tempURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent(".\(stem).osaurus-edit-\(UUID().uuidString.prefix(8)).\(ext)")
        do {
            try edited.write(to: tempURL, options: .withoutOverwriting)
        } catch {
            throw DocumentEditError("Couldn't stage the edit next to '\(displayPath)': \(error.localizedDescription)")
        }
        do {
            try await validate(tempURL, ext: ext)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }

        var diffText: String?
        var diffTruncated = false
        if let before = await FileDiffEngine.documentLines(fileURL),
            let after = await FileDiffEngine.documentLines(tempURL)
        {
            let diff = FileDiffEngine.textDiff(old: before, new: after, path: displayPath, existed: true)
            diffText = diff.rawDiff
            diffTruncated = diff.truncated
            if before == after {
                warnings.append("The document's text didn't change (layout, formatting, or annotations may have).")
            }
        }
        return PreparedEdit(
            fileURL: fileURL, tempURL: tempURL, originalData: original, summaries: summaries,
            warnings: warnings, diffText: diffText, diffTruncated: diffTruncated)
    }

    /// Re-open the staged file with the same parsers the app reads with.
    static func validate(_ url: URL, ext: String) async throws {
        if ext == "pdf" {
            guard let document = PDFDocument(url: url), document.pageCount > 0 else {
                throw DocumentEditError("The edited PDF didn't re-open cleanly, so it was discarded. The original is unchanged.")
            }
        }
        DocumentAdaptersBootstrap.registerBuiltIns()
        guard let adapter = DocumentFormatRegistry.shared.adapter(for: url) else {
            throw DocumentEditError("No reader is available to verify the edited .\(ext); nothing was written.")
        }
        let limit = max(DocumentLimits.limit(forFormatId: adapter.formatId), Int64(maxFileBytes))
        do {
            _ = try await adapter.parse(url: url, sizeLimit: limit)
        } catch DocumentAdapterError.emptyContent {
            return
        } catch {
            throw DocumentEditError(
                "The edited document failed verification (\(error.localizedDescription)), so it was discarded. The original is unchanged."
            )
        }
    }

    // MARK: - Structure

    static let structureListLimit = 400

    /// Addressable outline of a document: the ids `file_edit` operations use.
    static func structure(of url: URL) async throws -> [String: Any] {
        let ext = url.pathExtension.lowercased()
        var out: [String: Any] = ["format": ext, "operations": operationNames(for: ext)]
        switch ext {
        case "docx":
            let package = try OOXMLPackage(data: try Data(contentsOf: url))
            let editor = try DOCXEditor(package: package)
            let styles = try editor.paragraphStyleIds()
            let paragraphs = try editor.paragraphs()
            out["paragraphs"] = paragraphs.prefix(structureListLimit).enumerated().map { index, p -> [String: Any] in
                var entry: [String: Any] = ["index": index + 1, "text": OOXMLText.preview(OOXMLText.text(of: p))]
                if let style = DOCXEditor.styleId(of: p) { entry["style"] = styles[style] ?? style }
                return entry
            }
            out["paragraph_count"] = paragraphs.count
            out["tables"] = try editor.tables().enumerated().map { index, table -> [String: Any] in
                let rows = table.childElements("tr")
                return [
                    "index": index + 1,
                    "rows": rows.count,
                    "columns": rows.map { $0.childElements("tc").count }.max() ?? 0,
                    "first_row": rows.first.map { row in
                        row.childElements("tc").map { cell in
                            OOXMLText.preview(cell.childElements("p").map(OOXMLText.text(of:)).joined(separator: " "), max: 40)
                        }
                    } ?? [],
                ]
            }
            out["paragraph_styles"] = Array(styles.values.sorted().prefix(40))
            out["hint"] =
                "Paragraph `index` and table numbers are 1-based. replace_text {old_string, new_string, all?}; insert_paragraph {text, after|before, style?}; delete_paragraph {index}; set_table_cell {table, row, column, text}; append_markdown {markdown}."
        case "xlsx":
            let package = try OOXMLPackage(data: try Data(contentsOf: url))
            let editor = try XLSXEditor(package: package)
            let sheets = try editor.sheets()
            var workbook: Workbook?
            DocumentAdaptersBootstrap.registerBuiltIns()
            if let adapter = DocumentFormatRegistry.shared.adapter(for: url),
                let parsed = try? await adapter.parse(url: url, sizeLimit: Int64(maxFileBytes))
            {
                workbook = parsed.representation.underlying as? Workbook
            }
            out["sheets"] = try sheets.enumerated().map { index, sheet -> [String: Any] in
                var entry: [String: Any] = ["number": index + 1, "name": sheet.name]
                if let dimension = try package.root(sheet.part).firstChild("dimension")?.attr("ref") {
                    entry["used_range"] = dimension
                }
                if let parsed = workbook?.sheets.first(where: { $0.name == sheet.name }) {
                    var cells: [String] = []
                    outer: for row in parsed.rows {
                        for cell in row.cells {
                            let value = cell.value.fallbackText
                            guard !value.isEmpty || cell.formula != nil else { continue }
                            cells.append("\(cell.reference): \(value)" + (cell.formula.map { "  (=\($0))" } ?? ""))
                            if cells.count >= 80 { break outer }
                        }
                    }
                    entry["cells"] = cells
                    entry["rows"] = parsed.rows.count
                }
                return entry
            }
            out["hint"] =
                "Cells are addressed like B3 (sheet by name or 1-based number; default first sheet). set_cells {sheet?, cells: {\"B3\": 42, \"C3\": \"=SUM(B1:B2)\", \"D3\": null}}; insert_rows/delete_rows {sheet?, at, count?}; add_sheet {name, after?}; rename_sheet {sheet, name}; delete_sheet {sheet}."
        case "pptx":
            let package = try OOXMLPackage(data: try Data(contentsOf: url))
            let editor = try PPTXEditor(package: package)
            out["slides"] = try editor.slides().prefix(structureListLimit).enumerated().map { index, slide -> [String: Any] in
                let root = try package.root(slide.part)
                let shapes = PPTXEditor.textShapes(in: root).enumerated().map { shapeIndex, shape -> [String: Any] in
                    var entry: [String: Any] = [
                        "shape": shapeIndex + 1, "text": OOXMLText.preview(PPTXEditor.shapeText(shape)),
                    ]
                    if let type = PPTXEditor.placeholderType(shape) { entry["placeholder"] = type }
                    return entry
                }
                return ["slide": index + 1, "shapes": shapes]
            }
            out["hint"] =
                "Slides and shapes are 1-based. replace_text {old_string, new_string, all?, slide?}; set_slide_text {slide, shape: \"title\"|\"subtitle\"|\"body\"|number, text}; duplicate_slide {slide}; delete_slide {slide}; reorder_slides {order: [..]}."
        case "pdf":
            guard let document = PDFDocument(url: url) else { throw DocumentEditError("The PDF couldn't be opened.") }
            if document.isLocked { throw DocumentEditError("The PDF is password-protected.") }
            out["page_count"] = document.pageCount
            out["pages"] = (0..<min(document.pageCount, structureListLimit)).compactMap { index -> [String: Any]? in
                guard let page = document.page(at: index) else { return nil }
                let bounds = page.bounds(for: .cropBox)
                return [
                    "page": index + 1,
                    "size_pt": "\(Int(bounds.width))x\(Int(bounds.height))",
                    "rotation": page.rotation,
                    "text": OOXMLText.preview(page.string ?? "", max: 120),
                ]
            }
            if let editor = try? PDFEditor(data: try Data(contentsOf: url), resolvePath: { _ in url }) {
                let fields = editor.formFields()
                if !fields.isEmpty { out["form_fields"] = fields }
            }
            out["hint"] =
                "Pages are 1-based; x/y are points from the page's bottom-left. delete_pages {pages}; reorder_pages {order}; rotate_pages {pages?, degrees}; merge {files, after?}; fill_form {fields: {name: value}} (text: string; checkbox: true/false; radio: one of its `options`; choice: one of `options`; field names may be the short `label`); add_text {page, text, x?, y?, size?}; add_note {page, text}; highlight {text, page?}. Body text can't be rewritten in a PDF."
        default:
            throw DocumentEditError("Structure mode supports .docx, .xlsx, .pptx and .pdf.")
        }
        return out
    }
}
