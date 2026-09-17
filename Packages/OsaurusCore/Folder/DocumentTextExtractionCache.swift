//
//  DocumentTextExtractionCache.swift
//  osaurus
//
//  Searchable text for documents (`file_search` inside PDF / Word /
//  PowerPoint / Excel). Extraction runs through the same
//  `DocumentFormatRegistry` adapters `file_read` uses, split into units
//  that carry a human locator (`page 3`, `slide 2`, `Sheet1 row 5`,
//  `paragraph 12`) instead of a line number, because "line 12" of an
//  extracted text layer is not a line of the file. Results are cached per
//  path + mtime + size so a folder of PDFs is extracted once per edit,
//  not once per search.
//

import Foundation

/// One searchable unit of an extracted document.
struct DocumentSearchUnit: Sendable, Equatable {
    /// Human locator (`page 3`, `slide 2`, `Sheet1 row 5`, `paragraph 12`).
    let locator: String
    let text: String
}

/// Extracted units for a whole document plus what kind of locator they use.
struct ExtractedDocumentText: Sendable {
    let format: String
    let units: [DocumentSearchUnit]
    /// Total characters across units (cache accounting).
    var characterCount: Int { units.reduce(0) { $0 + $1.text.count } }
}

actor DocumentTextExtractionCache {
    static let shared = DocumentTextExtractionCache()

    /// Per-file byte cap for search-time extraction. Larger documents are
    /// reported as skipped with a `file_read` pointer instead of stalling
    /// the whole search on one giant file.
    static let maxDocumentBytes = 25 * 1024 * 1024
    /// Cache bounds: entries and total extracted characters.
    static let maxEntries = 128
    static let maxTotalCharacters = 16_000_000

    struct Key: Hashable, Sendable {
        let path: String
        let modified: Date
        let size: Int
    }

    private struct Entry {
        let value: ExtractedDocumentText
        var lastUsed: Date
    }

    private var entries: [Key: Entry] = [:]
    private var totalCharacters = 0

    /// Whether `file_search` looks inside this extension via document
    /// extraction. Derived from the read-support policy: every family with
    /// a registered adapter plus the workbook preview family.
    static func isSearchableDocument(extension ext: String) -> Bool {
        switch WorkspaceFileFormatPolicy.readSupport(for: ext) {
        case .extractedText, .workbook: return true
        default: return false
        }
    }

    enum ExtractionError: Error {
        case tooLarge(bytes: Int)
        case unsupported
        case failed
    }

    /// Extracted, cached search units for `url`. Throws `ExtractionError`
    /// when the document cannot be searched; the caller counts it as
    /// skipped and names the type in the search note.
    func units(
        for url: URL,
        registry: DocumentFormatRegistry = .shared
    ) async throws -> ExtractedDocumentText {
        let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let size = values.fileSize ?? 0
        guard size <= Self.maxDocumentBytes else { throw ExtractionError.tooLarge(bytes: size) }
        let key = Key(
            path: url.standardizedFileURL.path,
            modified: values.contentModificationDate ?? .distantPast,
            size: size
        )
        if var hit = entries[key] {
            hit.lastUsed = Date()
            entries[key] = hit
            return hit.value
        }
        let extracted = try await Self.extract(url: url, registry: registry)
        insert(extracted, for: key)
        return extracted
    }

    func removeAll() {
        entries.removeAll()
        totalCharacters = 0
    }

    var count: Int { entries.count }

    private func insert(_ value: ExtractedDocumentText, for key: Key) {
        let chars = value.characterCount
        // Evict least-recently-used entries until the bounds hold. A single
        // oversized extraction still caches (so the next search hits) but
        // evicts everything else.
        while !entries.isEmpty,
            entries.count + 1 > Self.maxEntries || totalCharacters + chars > Self.maxTotalCharacters
        {
            guard let victim = entries.min(by: { $0.value.lastUsed < $1.value.lastUsed }) else { break }
            totalCharacters -= victim.value.value.characterCount
            entries.removeValue(forKey: victim.key)
        }
        entries[key] = Entry(value: value, lastUsed: Date())
        totalCharacters += chars
    }

    // MARK: - Extraction

    private static func extract(
        url: URL,
        registry: DocumentFormatRegistry
    ) async throws -> ExtractedDocumentText {
        let ext = url.pathExtension.lowercased()
        guard isSearchableDocument(extension: ext) else { throw ExtractionError.unsupported }
        DocumentAdaptersBootstrap.registerBuiltIns(registry: registry)
        guard let adapter = registry.adapter(for: url) else { throw ExtractionError.unsupported }
        let document: StructuredDocument
        do {
            document = try await adapter.parse(
                url: url,
                sizeLimit: DocumentLimits.limit(forFormatId: adapter.formatId)
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as DocumentAdapterError {
            if case .emptyContent = error {
                return ExtractedDocumentText(format: ext, units: [])
            }
            if case .cancelled = error { throw CancellationError() }
            throw ExtractionError.failed
        } catch {
            throw ExtractionError.failed
        }
        try Task.checkCancellation()
        return ExtractedDocumentText(format: ext, units: units(from: document, ext: ext))
    }

    /// Split a parsed document into locator-bearing units by representation.
    static func units(from document: StructuredDocument, ext: String) -> [DocumentSearchUnit] {
        let underlying = document.representation.underlying
        if let pdf = underlying as? PDFDocumentRepresentation {
            return pdf.pages.flatMap { page in
                lines(of: page.text).map { DocumentSearchUnit(locator: "page \(page.pageIndex + 1)", text: $0) }
            }
        }
        if let presentation = underlying as? PresentationDocument {
            return presentation.slides.flatMap { slide -> [DocumentSearchUnit] in
                var slideUnits = lines(of: slide.text).map {
                    DocumentSearchUnit(locator: "slide \(slide.number)", text: $0)
                }
                if let notes = slide.speakerNotes {
                    slideUnits += lines(of: notes.text).map {
                        DocumentSearchUnit(locator: "slide \(slide.number) notes", text: $0)
                    }
                }
                return slideUnits
            }
        }
        if let workbook = underlying as? Workbook {
            return workbook.sheets.flatMap { sheet in
                sheet.rows.compactMap { row -> DocumentSearchUnit? in
                    let cells = row.cells.map { $0.value.fallbackText }
                    let joined = cells.joined(separator: "\t").trimmingCharacters(in: .whitespaces)
                    guard !joined.isEmpty else { return nil }
                    return DocumentSearchUnit(locator: "\(sheet.name) row \(row.number)", text: joined)
                }
            }
        }
        // Word-processing and other text-layer documents: paragraphs of
        // the extracted text (blank-line separated), numbered.
        var units: [DocumentSearchUnit] = []
        var paragraph = 0
        for block in document.textFallback.components(separatedBy: "\n\n") {
            let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            paragraph += 1
            for line in lines(of: trimmed) {
                units.append(DocumentSearchUnit(locator: "paragraph \(paragraph)", text: line))
            }
        }
        return units
    }

    private static func lines(of text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
