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
    /// The bytes as opened. PDFKit's re-serialization drops AcroForm
    /// entries it doesn't model (`/XFA`, `/DR`), so diagnostics that need
    /// them read the original.
    private let originalData: Data
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
        self.originalData = data
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
        if filledFormFields > 0 {
            // PDFKit regenerates each filled widget's appearance stream and
            // sets /NeedAppearances so Acrobat/Preview/Chrome redraw the
            // values. Verify rather than assume: a save that lacks the flag
            // may show stale (empty) boxes in viewers that trust /AP only.
            if data.range(of: Data("/NeedAppearances".utf8)) == nil {
                warnings.append(
                    "The saved form does not carry /NeedAppearances; some viewers may show the filled values only after clicking into a field.")
            }
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

    /// One logical AcroForm field: every widget that shares a
    /// fully-qualified name (a radio group has one widget per option; a
    /// text field printed on two pages has two widgets).
    struct FormField {
        enum Kind: String { case text, checkbox, radio, choice, button, signature }
        let name: String
        let kind: Kind
        let widgets: [(page: Int, annotation: PDFAnnotation)]

        /// Last dotted component with any `[n]` array suffix removed —
        /// what the form's author typed, and what a model reads off the
        /// page (`topmostSubform[0].Page1[0].Name[0]` → `Name`).
        var shortName: String { PDFEditor.shortFieldName(name) }
        var firstPage: Int { widgets.map(\.page).min() ?? 0 }
        var isReadOnly: Bool { widgets.contains { $0.annotation.isReadOnly } }

        /// Radio: the on-state name of every option, in page order.
        /// Checkbox: its single on-state name.
        var onStates: [String] {
            widgets.map(\.annotation.buttonWidgetStateString).filter { !$0.isEmpty && $0 != "Off" }
        }
    }

    /// Fully-qualified name → logical field, in first-appearance order.
    func formFieldGroups() -> [FormField] {
        var order: [String] = []
        var grouped: [String: [(page: Int, annotation: PDFAnnotation)]] = [:]
        for entry in widgets() {
            guard let name = entry.annotation.fieldName, !name.isEmpty else { continue }
            if grouped[name] == nil { order.append(name) }
            grouped[name, default: []].append(entry)
        }
        return order.map { name in
            let members = grouped[name] ?? []
            let first = members[0].annotation
            let kind: FormField.Kind
            let fieldType = first.value(forAnnotationKey: .widgetFieldType) as? String
            if first.widgetFieldType == .signature || fieldType == "Sig" || fieldType == "/Sig" {
                kind = .signature
            } else {
                switch first.widgetFieldType {
                case .button:
                    switch first.widgetControlType {
                    case .pushButtonControl: kind = .button
                    case .radioButtonControl: kind = .radio
                    default:
                        // A checkbox flagged without the radio bit but with
                        // several differently-named on-states is still a
                        // radio group in practice.
                        let onStates = Set(members.map(\.annotation.buttonWidgetStateString))
                        kind = members.count > 1 && onStates.count > 1 ? .radio : .checkbox
                    }
                case .choice: kind = .choice
                default: kind = .text
                }
            }
            return FormField(name: name, kind: kind, widgets: members)
        }
    }

    static func shortFieldName(_ name: String) -> String {
        let last = name.split(separator: ".").last.map(String.init) ?? name
        guard let bracket = last.firstIndex(of: "["), last.hasSuffix("]") else { return last }
        return String(last[..<bracket])
    }

    /// Lowercase alphanumerics only — the comparison key for the
    /// tolerant lookup (`Date of Birth` == `date_of_birth` == `DateOfBirth`).
    static func normalizedFieldKey(_ name: String) -> String {
        String(name.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    /// Model-facing inventory (also surfaced by `file_read` mode
    /// "structure" as `form_fields`).
    func formFields() -> [[String: Any]] {
        formFieldGroups().map { field in
            var out: [String: Any] = ["name": field.name, "type": field.kind.rawValue, "page": field.firstPage + 1]
            if field.shortName != field.name { out["label"] = field.shortName }
            if field.isReadOnly { out["read_only"] = true }
            let first = field.widgets[0].annotation
            switch field.kind {
            case .checkbox:
                out["value"] = first.buttonWidgetState == .onState
                if let on = field.onStates.first { out["on_value"] = on }
            case .radio:
                out["options"] = field.onStates
                out["value"] = field.widgets.first { $0.annotation.buttonWidgetState == .onState }?.annotation.buttonWidgetStateString ?? ""
            case .choice:
                out["value"] = first.widgetStringValue ?? ""
                if let options = first.choices { out["options"] = options }
            case .text:
                out["value"] = first.widgetStringValue ?? ""
            case .button:
                out["fillable"] = false
            case .signature:
                out["fillable"] = false
                out["value"] = first.widgetStringValue ?? ""
            }
            return out
        }
    }

    /// Resolve a model-supplied key to one logical field: exact
    /// fully-qualified name, then case-insensitive, then the short name,
    /// then the normalized key. Each tier must be unique or it is an error
    /// that lists the candidates.
    private func resolveField(_ key: String, in fields: [FormField], op: DocumentOperation) throws -> FormField {
        if let exact = fields.first(where: { $0.name == key }) { return exact }
        let tiers: [(String, (FormField) -> Bool)] = [
            ("case-insensitively", { $0.name.lowercased() == key.lowercased() }),
            ("by its short name", { $0.shortName.lowercased() == key.lowercased() }),
            ("ignoring punctuation and spacing", { Self.normalizedFieldKey($0.shortName) == Self.normalizedFieldKey(key) || Self.normalizedFieldKey($0.name) == Self.normalizedFieldKey(key) }),
        ]
        for (how, matches) in tiers {
            let hits = fields.filter(matches)
            if hits.count == 1 { return hits[0] }
            if hits.count > 1 {
                throw op.fail(
                    "\"\(key)\" matches \(hits.count) fields \(how): \(hits.map { "\"\($0.name)\"" }.joined(separator: ", ")). Use the full field name.")
            }
        }
        var message = "no field named \"\(key)\"."
        if let closest = Self.closestField(to: key, in: fields) {
            message += " Did you mean \"\(closest.name)\" (\(closest.kind.rawValue), page \(closest.firstPage + 1))?"
        }
        let fillable = fields.filter { $0.kind != .button && $0.kind != .signature }
        message += " Fields: \(fillable.prefix(40).map { "\"\($0.name)\"" }.joined(separator: ", "))."
        if fillable.count > 40 { message += " (\(fillable.count - 40) more — `file_read` mode \"structure\" lists them all.)" }
        throw op.fail(message)
    }

    private static func closestField(to key: String, in fields: [FormField]) -> FormField? {
        let target = normalizedFieldKey(key)
        guard target.count >= 3 else { return nil }
        var best: (FormField, Int)?
        for field in fields where field.kind != .button {
            for candidate in [field.shortName, field.name] {
                let norm = normalizedFieldKey(candidate)
                guard !norm.isEmpty else { continue }
                // Similarity = shared length minus edit distance, so a
                // transposition ("Nmae") or a dropped word still lands on
                // the intended field while unrelated names score nothing.
                let distance = editDistance(norm, target)
                let allowed = max(2, target.count / 3)
                let score: Int
                if norm.contains(target) || target.contains(norm) {
                    score = min(norm.count, target.count)
                } else if distance <= allowed {
                    score = max(norm.count, target.count) - distance
                } else {
                    continue
                }
                if score > (best?.1 ?? 0) { best = (field, score) }
            }
        }
        guard let best, best.1 >= max(2, target.count / 2) else { return nil }
        return best.0
    }

    /// Levenshtein distance on unicode scalars (names are short).
    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a.unicodeScalars), b = Array(b.unicodeScalars)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    private func fillForm(_ op: DocumentOperation) throws {
        guard let fields = op.args["fields"] as? [String: Any], !fields.isEmpty else {
            throw op.fail("`fields` must map form field names to values, e.g. {\"Name\": \"Ada\", \"Agree\": true}.")
        }
        let groups = formFieldGroups()
        guard !groups.isEmpty else { throw op.fail(noFormFieldsExplanation()) }

        // Resolve every key before touching any widget so a typo in the
        // last field can't leave the form half-filled.
        var planned: [(key: String, field: FormField, raw: Any)] = []
        var seen: Set<String> = []
        for key in fields.keys.sorted() {
            let field = try resolveField(key, in: groups, op: op)
            guard !seen.contains(field.name) else {
                throw op.fail("\"\(key)\" and another key both resolve to field \"\(field.name)\"; pass it once.")
            }
            seen.insert(field.name)
            switch field.kind {
            case .button:
                throw op.fail("\"\(field.name)\" is a push button (it runs an action), not a fillable field.")
            case .signature:
                throw op.fail("\"\(field.name)\" is a digital signature field; Osaurus can't sign PDFs. Fill the other fields and leave signing to the signer.")
            default: break
            }
            if field.isReadOnly {
                throw op.fail("\"\(field.name)\" is read-only in this form; it can't be filled.")
            }
            planned.append((key, field, fields[key] ?? NSNull()))
        }

        var filled: [String] = []
        for (_, field, raw) in planned {
            switch field.kind {
            case .checkbox:
                let onName = field.onStates.first
                let on = try Self.truthy(raw, onState: onName, field: field, op: op)
                for entry in field.widgets { entry.annotation.buttonWidgetState = on ? .onState : .offState }
                filled.append("\(field.shortName)=\(on ? (onName ?? "on") : "off")")
            case .radio:
                let options = field.onStates
                if raw is NSNull || (raw as? Bool) == false || ("\(raw)".isEmpty) {
                    for entry in field.widgets { entry.annotation.buttonWidgetState = .offState }
                    filled.append("\(field.shortName)=off")
                    continue
                }
                let wanted = "\(raw)"
                guard let choice = options.first(where: { $0 == wanted }) ?? options.first(where: { $0.lowercased() == wanted.lowercased() })
                    ?? options.first(where: { Self.normalizedFieldKey($0) == Self.normalizedFieldKey(wanted) })
                else {
                    throw op.fail("\"\(wanted)\" isn't an option for radio group \"\(field.name)\". Options: \(options.joined(separator: ", ")).")
                }
                for entry in field.widgets {
                    entry.annotation.buttonWidgetState = entry.annotation.buttonWidgetStateString == choice ? .onState : .offState
                }
                filled.append("\(field.shortName)=\(choice)")
            case .choice:
                let value = raw is NSNull ? "" : "\(raw)"
                let first = field.widgets[0].annotation
                if let options = first.choices, !options.isEmpty, !value.isEmpty, !options.contains(value) {
                    if let relaxed = options.first(where: { $0.lowercased() == value.lowercased() }) {
                        for entry in field.widgets { entry.annotation.widgetStringValue = relaxed }
                        filled.append("\(field.shortName)=\(relaxed)")
                        continue
                    }
                    throw op.fail("\"\(value)\" isn't an option for \"\(field.name)\". Options: \(options.joined(separator: ", ")).")
                }
                for entry in field.widgets { entry.annotation.widgetStringValue = value }
                filled.append("\(field.shortName)=\(value)")
            case .text:
                let value: String
                switch raw {
                case is NSNull: value = ""
                case let b as Bool: value = b ? "Yes" : "No"
                default: value = "\(raw)"
                }
                if value.contains("\n"), !field.widgets[0].annotation.isMultiline {
                    warnings.append("\"\(field.name)\" is a single-line field; the line breaks in its value will show as one line.")
                }
                for entry in field.widgets { entry.annotation.widgetStringValue = value }
                filled.append("\(field.shortName)=\(OOXMLText.preview(value, max: 40))")
            case .button, .signature:
                continue
            }
        }
        filledFormFields += filled.count
        summaries.append("Filled \(filled.count) form field\(filled.count == 1 ? "" : "s"): \(filled.joined(separator: ", "))")
    }

    private var filledFormFields = 0

    private static func truthy(_ raw: Any, onState: String?, field: FormField, op: DocumentOperation) throws -> Bool {
        switch raw {
        case let b as Bool: return b
        case let n as NSNumber: return n.boolValue
        case is NSNull: return false
        case let s as String:
            let lower = s.trimmingCharacters(in: .whitespaces).lowercased()
            if ["true", "yes", "on", "1", "x", "checked"].contains(lower) { return true }
            if ["false", "no", "off", "0", "", "unchecked"].contains(lower) { return false }
            if let onState, lower == onState.lowercased() { return true }
            throw op.fail("\"\(s)\" isn't a checkbox value for \"\(field.name)\"; pass true/false\(onState.map { " (or its on-value \"\($0)\")" } ?? "").")
        default:
            throw op.fail("\"\(field.name)\" is a checkbox; pass true or false.")
        }
    }

    /// Why `fill_form` has nothing to fill — distinguishes an XFA form
    /// (LiveCycle; PDFKit exposes no widgets) from a flattened form whose
    /// blanks are just printed text, and for the latter lists the label
    /// positions so `add_text` can place values next to them.
    private func noFormFieldsExplanation() -> String {
        if isXFAForm {
            return "this PDF is an XFA form (Adobe LiveCycle); its fields aren't AcroForm widgets, so they can't be filled here. Open it in Adobe Acrobat, or ask for an AcroForm/flattened version."
        }
        var message = "this PDF has no fillable form fields (the blanks are printed text, not widgets)."
        let labels = printedLabels(limit: 8)
        if !labels.isEmpty {
            message += " To fill it anyway, place values with `add_text` at these label positions (x/y are points from the page's bottom-left; put the text box just right of the label):\n"
            message += labels.map { "  page \($0.page): \"\($0.text)\" ends at x=\($0.x), y=\($0.y)" }.joined(separator: "\n")
        } else {
            message += " Use `add_text` with `page`, `x`, `y` to place values on the page."
        }
        return message
    }

    /// Raw-byte check for an `/XFA` entry; cheap and reliable enough for a
    /// diagnostic (PDFKit exposes no AcroForm dictionary).
    private var isXFAForm: Bool {
        originalData.range(of: Data("/XFA".utf8)) != nil
    }

    /// Lines that look like form labels ("Name:", "Date of birth: ____")
    /// with the point where the label's text ends.
    private func printedLabels(limit: Int) -> [(page: Int, text: String, x: Int, y: Int)] {
        var out: [(Int, String, Int, Int)] = []
        for index in 0..<pageCount {
            guard let page = document.page(at: index), let text = page.string else { continue }
            for rawLine in text.components(separatedBy: .newlines) {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty else { continue }
                let label: String
                if let colon = line.firstIndex(of: ":") {
                    label = String(line[...colon])
                } else if line.contains("____") {
                    label = line.replacingOccurrences(of: "_", with: "").trimmingCharacters(in: .whitespaces)
                } else {
                    continue
                }
                guard !label.isEmpty, label.count <= 60 else { continue }
                guard let selection = document.findString(label, withOptions: []).first(where: { $0.pages.contains(page) }) else { continue }
                let rect = selection.bounds(for: page)
                out.append((index + 1, label, Int(rect.maxX.rounded()), Int(rect.minY.rounded())))
                if out.count >= limit { return out }
            }
        }
        return out
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
