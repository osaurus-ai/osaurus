//
//  PPTXAdapter.swift
//  osaurus
//
//  Read-only PPTX/POTX adapter. It uses a small bounded ZIP reader for the
//  OpenXML parts needed for slide text and speaker notes, avoiding shell
//  extraction and failing closed on archive features this lane does not need.
//

import Compression
import Foundation

/// Extracts basic text-bearing presentation structure without claiming to
/// support the full OOXML drawing, media, chart, or layout model.
public struct PPTXAdapter: DocumentFormatAdapter {
    public static let id = "pptx"

    public let formatId = PPTXAdapter.id

    public init() {}

    public func canHandle(url: URL, uti: String?) -> Bool {
        let fileExtension = url.pathExtension.lowercased()
        if ["pptx", "potx"].contains(fileExtension) {
            return true
        }

        guard let uti else { return false }
        return [
            "org.openxmlformats.presentationml.presentation",
            "org.openxmlformats.presentationml.template",
            "com.microsoft.powerpoint.pptx",
            "com.microsoft.powerpoint.potx",
        ].contains(uti)
    }

    public func parse(url: URL, sizeLimit: Int64) async throws -> StructuredDocument {
        try Task.checkCancellation()

        let fileSize = try Self.fileSize(for: url)
        let effectiveLimit = sizeLimit > 0 ? sizeLimit : DocumentLimits.presentation
        if fileSize > effectiveLimit {
            throw DocumentAdapterError.sizeLimitExceeded(actual: fileSize, limit: effectiveLimit)
        }
        guard fileSize <= Int64(Int.max) else {
            throw DocumentAdapterError.sizeLimitExceeded(actual: fileSize, limit: Int64(Int.max))
        }

        do {
            let maxArchiveBytes = Int(min(effectiveLimit, Int64(Int.max)))
            let archive = try BoundedZipReader(url: url, maxArchiveBytes: maxArchiveBytes)
            let presentation = try await Self.parsePresentation(from: archive, url: url)
            let built = Self.buildFallbackAndStructure(for: presentation, filename: url.lastPathComponent)
            let textFallback = PlainTextAdapter.applyCharacterCap(built.text)
            guard !textFallback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw DocumentAdapterError.emptyContent
            }

            let security = try Self.securityMetadata(
                for: url,
                presentation: presentation,
                archive: archive,
                extractedText: built.text,
                textFallback: textFallback
            )
            let structure =
                built.text == textFallback
                ? built.structure
                : DocumentStructure.plainText(filename: url.lastPathComponent, text: textFallback)

            return StructuredDocument(
                formatId: formatId,
                filename: url.lastPathComponent,
                fileSize: fileSize,
                representation: AnyStructuredRepresentation(
                    formatId: formatId,
                    underlying: presentation
                ),
                structure: structure,
                security: security,
                textFallback: textFallback
            )
        } catch is CancellationError {
            throw DocumentAdapterError.cancelled
        } catch let error as DocumentAdapterError {
            throw error
        } catch {
            throw DocumentAdapterError.readFailed(underlying: error.localizedDescription)
        }
    }

    // MARK: - Presentation parse

    private static func parsePresentation(
        from archive: BoundedZipReader,
        url: URL
    ) async throws -> PresentationDocument {
        let slideParts = try slideParts(in: archive)
        guard !slideParts.isEmpty else {
            throw DocumentAdapterError.readFailed(underlying: "PPTX package contains no slide XML parts.")
        }

        var slides: [PresentationSlide] = []
        for (index, slidePart) in slideParts.enumerated() {
            try Task.checkCancellation()

            let slideExtraction = try textRunExtraction(
                in: slidePart.path,
                from: archive,
                slideIndex: index,
                region: .slideText
            )
            let notesPart = try notesPart(for: slidePart, in: archive)
            let speakerNotes = try notesPart.map { part in
                PresentationSpeakerNotes(
                    sourcePart: part,
                    anchorId: notesAnchorId(slideIndex: index),
                    textRuns: try textRuns(
                        in: part,
                        from: archive,
                        slideIndex: index,
                        region: .speakerNotes
                    )
                )
            }

            slides.append(
                PresentationSlide(
                    index: index,
                    number: slidePart.number,
                    sourcePart: slidePart.path,
                    label: "Slide \(index + 1)",
                    isHidden: slideExtraction.isHiddenSlide,
                    textRuns: slideExtraction.textRuns,
                    tables: slideExtraction.tables,
                    speakerNotes: speakerNotes?.text.isEmpty == false ? speakerNotes : nil
                )
            )
        }

        let kind: PresentationDocumentKind = url.pathExtension.lowercased() == "potx" ? .template : .presentation
        return PresentationDocument(
            kind: kind,
            sourceName: url.lastPathComponent,
            slides: slides
        )
    }

    private static func slideParts(in archive: BoundedZipReader) throws -> [SlidePart] {
        let ordered = try slidePartsFromPresentationRelationships(in: archive)
        if !ordered.isEmpty {
            return ordered
        }

        return archive.entryNames.compactMap { path -> SlidePart? in
            guard path.hasPrefix("ppt/slides/slide"), path.hasSuffix(".xml"),
                let number = numberedPart(path: path, prefix: "ppt/slides/slide")
            else {
                return nil
            }
            return SlidePart(number: number, path: path)
        }
        .sorted {
            if $0.number == $1.number {
                return $0.path < $1.path
            }
            return $0.number < $1.number
        }
    }

    private static func slidePartsFromPresentationRelationships(
        in archive: BoundedZipReader
    ) throws -> [SlidePart] {
        guard archive.contains("ppt/presentation.xml"),
            archive.contains("ppt/_rels/presentation.xml.rels")
        else {
            return []
        }

        let slideIds = try slideRelationshipIds(in: "ppt/presentation.xml", from: archive)
        guard !slideIds.isEmpty else { return [] }

        let relationships = try relationships(in: "ppt/_rels/presentation.xml.rels", from: archive)
        var byId: [String: OpenXMLRelationship] = [:]
        for relationship in relationships where byId[relationship.id] == nil {
            byId[relationship.id] = relationship
        }
        return slideIds.compactMap { relationshipId -> SlidePart? in
            guard let relationship = byId[relationshipId],
                relationship.targetMode != .external,
                relationship.type.contains("/slide"),
                let path = resolveRelationshipTarget(
                    from: "ppt/presentation.xml",
                    target: relationship.target
                ),
                archive.contains(path)
            else {
                return nil
            }
            return SlidePart(
                number: numberedPart(path: path, prefix: "ppt/slides/slide") ?? 1,
                path: path
            )
        }
    }

    private static func notesPart(
        for slide: SlidePart,
        in archive: BoundedZipReader
    ) throws -> String? {
        let relationshipsPath = relationshipsPart(for: slide.path)
        if archive.contains(relationshipsPath) {
            let relationships = try relationships(in: relationshipsPath, from: archive)
            for relationship in relationships
            where relationship.targetMode != .external && relationship.type.contains("/notesSlide") {
                guard let path = resolveRelationshipTarget(from: slide.path, target: relationship.target) else {
                    continue
                }
                if archive.contains(path) {
                    return path
                }
            }
        }

        let fallback = "ppt/notesSlides/notesSlide\(slide.number).xml"
        return archive.contains(fallback) ? fallback : nil
    }

    private static func textRuns(
        in part: String,
        from archive: BoundedZipReader,
        slideIndex: Int,
        region: PresentationTextRegion
    ) throws -> [PresentationTextRun] {
        try textRunExtraction(
            in: part,
            from: archive,
            slideIndex: slideIndex,
            region: region
        ).textRuns
    }

    private static func textRunExtraction(
        in part: String,
        from archive: BoundedZipReader,
        slideIndex: Int,
        region: PresentationTextRegion
    ) throws -> PresentationPartTextExtraction {
        let data = try archive.entryData(part, maxUncompressedBytes: Constants.maxXMLPartBytes)
        let collector = OpenXMLTextRunCollector(maxUTF16Length: Constants.maxTextPartUTF16)
        let parser = XMLParser(data: data)
        parser.delegate = collector
        parser.shouldResolveExternalEntities = false

        guard parser.parse() else {
            if collector.didOverflow {
                throw DocumentAdapterError.readFailed(
                    underlying: "\(part) exceeded the PPTX text extraction limit."
                )
            }
            if collector.didExceedDepth {
                throw DocumentAdapterError.readFailed(
                    underlying: "\(part) exceeded the PPTX XML nesting limit."
                )
            }
            let message = parser.parserError?.localizedDescription ?? "Invalid XML in \(part)."
            throw DocumentAdapterError.readFailed(underlying: message)
        }

        return PresentationPartTextExtraction(
            textRuns: collector.runs.map { run in
                PresentationTextRun(
                    text: run.text,
                    paragraphIndex: run.paragraphIndex,
                    runIndex: run.runIndex,
                    sourcePart: part,
                    anchorId: textRunAnchorId(
                        slideIndex: slideIndex,
                        region: region,
                        paragraphIndex: run.paragraphIndex,
                        runIndex: run.runIndex
                    )
                )
            },
            tables: collector.tables.enumerated().map { tableIndex, table in
                PresentationTable(
                    index: tableIndex,
                    sourcePart: part,
                    anchorId: tableAnchorId(slideIndex: slideIndex, tableIndex: tableIndex),
                    rows: table.rows.enumerated().map { rowIndex, row in
                        PresentationTableRow(
                            index: rowIndex,
                            anchorId: tableRowAnchorId(
                                slideIndex: slideIndex,
                                tableIndex: tableIndex,
                                rowIndex: rowIndex
                            ),
                            cells: row.cells.enumerated().map { columnIndex, cell in
                                PresentationTableCell(
                                    rowIndex: rowIndex,
                                    columnIndex: columnIndex,
                                    text: cell.text,
                                    paragraphIndexes: cell.paragraphIndexes,
                                    anchorId: tableCellAnchorId(
                                        slideIndex: slideIndex,
                                        tableIndex: tableIndex,
                                        rowIndex: rowIndex,
                                        columnIndex: columnIndex
                                    )
                                )
                            }
                        )
                    }
                )
            },
            isHiddenSlide: collector.isHiddenSlide
        )
    }

    private static func slideRelationshipIds(
        in part: String,
        from archive: BoundedZipReader
    ) throws -> [String] {
        let data = try archive.entryData(part, maxUncompressedBytes: Constants.maxXMLPartBytes)
        let collector = OpenXMLSlideOrderCollector()
        let parser = XMLParser(data: data)
        parser.delegate = collector
        parser.shouldResolveExternalEntities = false

        guard parser.parse() else {
            let message = parser.parserError?.localizedDescription ?? "Invalid XML in \(part)."
            throw DocumentAdapterError.readFailed(underlying: message)
        }
        return collector.relationshipIds
    }

    private static func relationships(
        in part: String,
        from archive: BoundedZipReader
    ) throws -> [OpenXMLRelationship] {
        let data = try archive.entryData(part, maxUncompressedBytes: Constants.maxXMLPartBytes)
        let collector = OpenXMLRelationshipCollector()
        let parser = XMLParser(data: data)
        parser.delegate = collector
        parser.shouldResolveExternalEntities = false

        guard parser.parse() else {
            let message = parser.parserError?.localizedDescription ?? "Invalid XML in \(part)."
            throw DocumentAdapterError.readFailed(underlying: message)
        }
        return collector.relationships
    }

    // MARK: - Fallback and structure

    private static func buildFallbackAndStructure(
        for presentation: PresentationDocument,
        filename: String
    ) -> (text: String, structure: DocumentStructure) {
        let rootAnchor = DocumentAnchor.root(label: filename)
        var text = ""
        var slideElements: [DocumentElement] = []

        for slide in presentation.slides {
            if !text.isEmpty {
                text.append("\n\n")
            }
            let slideStart = text.utf16.count
            text.append(slide.label)

            let slideTextAppend = appendParagraphElements(
                runs: slide.textRuns,
                slide: slide,
                region: .slideText,
                text: &text
            )
            var children = slideTextAppend.elements
            children.append(
                contentsOf: tableElements(
                    tables: slide.tables,
                    slide: slide,
                    paragraphRanges: slideTextAppend.paragraphRanges
                )
            )

            if let notes = slide.speakerNotes, !notes.text.isEmpty {
                text.append("\nSpeaker notes:")
                let appended = appendParagraphElements(
                    runs: notes.textRuns,
                    slide: slide,
                    region: .speakerNotes,
                    text: &text
                )
                let notesAnchor = DocumentAnchor(
                    id: notes.anchorId,
                    kind: .speakerNotes,
                    path: [
                        .init(kind: .document),
                        .init(kind: .slide, index: slide.index),
                        .init(kind: .speakerNotes),
                    ],
                    textRange: DocumentTextRange(
                        startUTF16Offset: appended.textStart,
                        length: appended.textEnd - appended.textStart
                    ),
                    sourceRange: .init(
                        start: DocumentSourceLocation(
                            slideIndex: slide.index,
                            namedRegion: "speakerNotes"
                        )
                    ),
                    label: "\(slide.label) speaker notes",
                    metadata: ["sourcePart": notes.sourcePart]
                )
                children.append(
                    DocumentElement(
                        kind: .speakerNotes,
                        anchor: notesAnchor,
                        text: notes.text,
                        attributes: .init(role: "speakerNotes"),
                        children: appended.elements
                    )
                )
            }

            let slideMetadata = slideMetadata(slide)
            let slideAnchor = DocumentAnchor(
                id: slideAnchorId(slideIndex: slide.index),
                kind: .slide,
                path: [
                    .init(kind: .document),
                    .init(kind: .slide, index: slide.index),
                ],
                textRange: DocumentTextRange(
                    startUTF16Offset: slideStart,
                    length: text.utf16.count - slideStart
                ),
                sourceRange: .init(start: .slide(slide.index)),
                label: slide.label,
                metadata: slideMetadata
            )
            slideElements.append(
                DocumentElement(
                    kind: .slide,
                    anchor: slideAnchor,
                    text: slide.text,
                    attributes: .init(metadata: slideMetadata),
                    children: children
                )
            )
        }

        let root = DocumentElement(
            id: rootAnchor.id,
            kind: .document,
            anchor: rootAnchor,
            children: slideElements
        )
        return (
            text,
            DocumentStructure(root: root, textLengthUTF16: text.utf16.count)
        )
    }

    private static func appendParagraphElements(
        runs: [PresentationTextRun],
        slide: PresentationSlide,
        region: PresentationTextRegion,
        text: inout String
    ) -> ParagraphAppendResult {
        let paragraphs = groupedParagraphs(runs)
        var elements: [DocumentElement] = []
        var firstStart: Int?

        for paragraph in paragraphs {
            text.append("\n")
            let paragraphStart = text.utf16.count
            firstStart = firstStart ?? paragraphStart
            var runOffset = 0
            var runElements: [DocumentElement] = []
            let paragraphText = paragraph.runs.map(\.text).joined()

            for run in paragraph.runs {
                let range = DocumentTextRange(
                    startUTF16Offset: paragraphStart + runOffset,
                    length: run.text.utf16.count
                )
                let anchor = DocumentAnchor(
                    id: run.anchorId,
                    kind: .run,
                    path: anchorPath(
                        slideIndex: slide.index,
                        region: region,
                        paragraphIndex: paragraph.index,
                        runIndex: run.runIndex
                    ),
                    textRange: range,
                    sourceRange: .init(
                        start: DocumentSourceLocation(
                            slideIndex: slide.index,
                            paragraphIndex: paragraph.index,
                            runIndex: run.runIndex,
                            namedRegion: region.sourceRegionName
                        )
                    ),
                    label: "\(slide.label) \(region.label) run \(paragraph.index + 1).\(run.runIndex + 1)",
                    metadata: ["sourcePart": run.sourcePart]
                )
                runElements.append(
                    DocumentElement(
                        kind: .run,
                        anchor: anchor,
                        text: run.text,
                        attributes: .init(role: region.rawValue)
                    )
                )
                runOffset += run.text.utf16.count
            }

            text.append(paragraphText)
            let paragraphAnchor = DocumentAnchor(
                id: paragraphAnchorId(
                    slideIndex: slide.index,
                    region: region,
                    paragraphIndex: paragraph.index
                ),
                kind: .paragraph,
                path: anchorPath(
                    slideIndex: slide.index,
                    region: region,
                    paragraphIndex: paragraph.index
                ),
                textRange: DocumentTextRange(
                    startUTF16Offset: paragraphStart,
                    length: paragraphText.utf16.count
                ),
                sourceRange: .init(
                    start: DocumentSourceLocation(
                        slideIndex: slide.index,
                        paragraphIndex: paragraph.index,
                        namedRegion: region.sourceRegionName
                    )
                ),
                label: "\(slide.label) \(region.label) paragraph \(paragraph.index + 1)",
                metadata: ["sourcePart": paragraph.runs.first?.sourcePart ?? slide.sourcePart]
            )
            elements.append(
                DocumentElement(
                    kind: region == .slideText && paragraph.index == 0 ? .heading : .paragraph,
                    anchor: paragraphAnchor,
                    text: paragraphText,
                    attributes: .init(role: region.rawValue),
                    children: runElements
                )
            )
        }

        let textEnd = text.utf16.count
        return ParagraphAppendResult(
            elements: elements,
            textStart: firstStart ?? textEnd,
            textEnd: textEnd,
            paragraphRanges: Dictionary(
                uniqueKeysWithValues: elements.compactMap { element in
                    guard let range = element.anchor.textRange,
                        let paragraphIndex = element.anchor.sourceRange?.start.paragraphIndex
                    else {
                        return nil
                    }
                    return (paragraphIndex, range)
                }
            )
        )
    }

    private static func tableElements(
        tables: [PresentationTable],
        slide: PresentationSlide,
        paragraphRanges: [Int: DocumentTextRange]
    ) -> [DocumentElement] {
        tables.compactMap { table in
            let rowElements = table.rows.map { row in
                let cellElements = row.cells.map { cell in
                    let range = spanningRange(
                        cell.paragraphIndexes.compactMap { paragraphRanges[$0] }
                    )
                    let anchor = DocumentAnchor(
                        id: cell.anchorId,
                        kind: .cell,
                        path: tableAnchorPath(
                            slideIndex: slide.index,
                            tableIndex: table.index,
                            rowIndex: row.index,
                            columnIndex: cell.columnIndex
                        ),
                        textRange: range,
                        sourceRange: .init(
                            start: DocumentSourceLocation(
                                slideIndex: slide.index,
                                rowIndex: row.index,
                                columnIndex: cell.columnIndex,
                                namedRegion: "table"
                            )
                        ),
                        label:
                            "\(slide.label) table \(table.index + 1) cell \(row.index + 1).\(cell.columnIndex + 1)",
                        metadata: [
                            "sourcePart": table.sourcePart,
                            "tableIndex": "\(table.index)",
                            "rowIndex": "\(row.index)",
                            "columnIndex": "\(cell.columnIndex)",
                        ]
                    )
                    return DocumentElement(
                        kind: .tableCell,
                        anchor: anchor,
                        text: cell.text,
                        attributes: .init(role: "tableCell")
                    )
                }
                let rowRange = spanningRange(cellElements.compactMap { $0.anchor.textRange })
                let rowAnchor = DocumentAnchor(
                    id: row.anchorId,
                    kind: .row,
                    path: tableAnchorPath(slideIndex: slide.index, tableIndex: table.index, rowIndex: row.index),
                    textRange: rowRange,
                    sourceRange: .init(
                        start: DocumentSourceLocation(
                            slideIndex: slide.index,
                            rowIndex: row.index,
                            namedRegion: "table"
                        )
                    ),
                    label: "\(slide.label) table \(table.index + 1) row \(row.index + 1)",
                    metadata: [
                        "sourcePart": table.sourcePart,
                        "tableIndex": "\(table.index)",
                        "rowIndex": "\(row.index)",
                        "columnCount": "\(row.cells.count)",
                    ]
                )
                return DocumentElement(
                    kind: .tableRow,
                    anchor: rowAnchor,
                    text: row.text,
                    attributes: .init(role: "tableRow"),
                    children: cellElements
                )
            }
            guard rowElements.contains(where: { !$0.children.isEmpty }) else { return nil }

            let tableRange = spanningRange(rowElements.compactMap { $0.anchor.textRange })
            let tableAnchor = DocumentAnchor(
                id: table.anchorId,
                kind: .table,
                path: tableAnchorPath(slideIndex: slide.index, tableIndex: table.index),
                textRange: tableRange,
                sourceRange: .init(
                    start: DocumentSourceLocation(slideIndex: slide.index, namedRegion: "table")
                ),
                label: "\(slide.label) table \(table.index + 1)",
                metadata: [
                    "sourcePart": table.sourcePart,
                    "tableIndex": "\(table.index)",
                    "rowCount": "\(table.rows.count)",
                    "columnCount": "\(table.columnCount)",
                ]
            )
            return DocumentElement(
                kind: .table,
                anchor: tableAnchor,
                text: table.text,
                attributes: .init(role: "table"),
                children: rowElements
            )
        }
    }

    private static func spanningRange(_ ranges: [DocumentTextRange]) -> DocumentTextRange? {
        guard let start = ranges.map(\.startUTF16Offset).min(),
            let end = ranges.map(\.endUTF16Offset).max()
        else {
            return nil
        }
        return DocumentTextRange(startUTF16Offset: start, length: end - start)
    }

    private static func groupedParagraphs(
        _ runs: [PresentationTextRun]
    ) -> [PresentationParagraphRuns] {
        let grouped = Dictionary(grouping: runs, by: \.paragraphIndex)
        return grouped.keys.sorted().compactMap { index in
            guard let runs = grouped[index] else { return nil }
            let sorted = runs.sorted { $0.runIndex < $1.runIndex }
            let text = sorted.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return PresentationParagraphRuns(index: index, runs: sorted)
        }
    }

    private static func slideMetadata(_ slide: PresentationSlide) -> [String: String] {
        var metadata = [
            "sourcePart": slide.sourcePart,
            "slideNumber": "\(slide.number)",
        ]
        if slide.isHidden {
            metadata["isHidden"] = "true"
        }
        return metadata
    }

    // MARK: - Security

    private static func securityMetadata(
        for url: URL,
        presentation: PresentationDocument,
        archive: BoundedZipReader,
        extractedText: String,
        textFallback: String
    ) throws -> DocumentSecurityMetadata {
        var findings: [DocumentSecurityFinding] = [
            DocumentSecurityFinding(
                kind: .unsupportedFeature,
                severity: .informational,
                message:
                    "PPTX/POTX adapter extracts slide text, speaker notes, and package relationships; media, charts, comments, and layout are not fully interpreted."
            )
        ]
        var activeContentTypes: Set<DocumentActiveContentType> = []
        var externalReferences: [DocumentExternalReference] = []

        let macroParts = archive.entryNames.filter { $0.lowercased().hasSuffix("vbaproject.bin") }
        let embeddedObjectParts = archive.entryNames.filter { path in
            let lowercased = path.lowercased()
            return !lowercased.hasSuffix("/")
                && (lowercased.hasPrefix("ppt/embeddings/")
                    || lowercased.hasPrefix("ppt/activex/")
                    || lowercased.hasPrefix("ppt/ctrlprops/"))
        }
        let relationshipParts = archive.entryNames.filter { $0.hasSuffix(".rels") }
        let inspectedRelationshipParts = Array(relationshipParts.prefix(Constants.maxRelationshipFiles))
        var macroRelationshipCount = 0
        var embeddedObjectRelationshipCount = 0

        for relationshipsPart in inspectedRelationshipParts {
            for relationship in try relationships(in: relationshipsPart, from: archive) {
                if relationship.isMacroProject {
                    macroRelationshipCount += 1
                }
                if relationship.isEmbeddedObject {
                    embeddedObjectRelationshipCount += 1
                }
                if relationship.targetMode == .external {
                    activeContentTypes.insert(.externalReference)
                    externalReferences.append(
                        DocumentExternalReference(
                            kind: relationship.referenceKind,
                            urlString: relationship.target,
                            relationshipId: relationship.id
                        )
                    )
                }
            }
        }

        if !macroParts.isEmpty || macroRelationshipCount > 0 {
            activeContentTypes.insert(.macro)
            findings.append(
                DocumentSecurityFinding(
                    kind: .macro,
                    severity: .high,
                    message: "Presentation package contains a VBA project part or relationship.",
                    metadata: [
                        "partCount": "\(macroParts.count)",
                        "relationshipCount": "\(macroRelationshipCount)",
                    ]
                )
            )
        }

        let embeddedCount = embeddedObjectParts.count + embeddedObjectRelationshipCount
        if embeddedCount > 0 {
            activeContentTypes.insert(.embeddedFile)
            findings.append(
                DocumentSecurityFinding(
                    kind: .embeddedFile,
                    severity: .medium,
                    message: "Presentation package contains embedded OLE/object or ActiveX parts/relationships.",
                    metadata: [
                        "count": "\(embeddedCount)",
                        "partCount": "\(embeddedObjectParts.count)",
                        "relationshipCount": "\(embeddedObjectRelationshipCount)",
                    ]
                )
            )
        }

        if !externalReferences.isEmpty {
            findings.append(
                DocumentSecurityFinding(
                    kind: .externalReference,
                    severity: .low,
                    message: "Presentation package contains external relationship targets.",
                    metadata: ["count": "\(externalReferences.count)"]
                )
            )
        }

        if relationshipParts.count > inspectedRelationshipParts.count {
            findings.append(
                DocumentSecurityFinding(
                    kind: .truncatedContent,
                    severity: .low,
                    message: "Presentation relationship inspection was capped before all relationship parts were read.",
                    metadata: [
                        "inspectedRelationshipFiles": "\(inspectedRelationshipParts.count)",
                        "relationshipFiles": "\(relationshipParts.count)",
                    ]
                )
            )
        }

        let hiddenSlides = presentation.slides.filter(\.isHidden)
        if !hiddenSlides.isEmpty {
            findings.append(
                DocumentSecurityFinding(
                    kind: .unsupportedFeature,
                    severity: .low,
                    message: "Presentation contains hidden slides; their text was extracted and marked in metadata.",
                    metadata: [
                        "feature": "hiddenSlides",
                        "count": "\(hiddenSlides.count)",
                        "slideNumbers": hiddenSlides.map(\.number).sorted().map(String.init).joined(separator: ","),
                    ]
                )
            )
        }

        if extractedText != textFallback {
            findings.append(
                DocumentSecurityFinding(
                    kind: .truncatedContent,
                    severity: .low,
                    message: "Presentation text fallback was character-capped; slide-level ranges were not preserved.",
                    metadata: [
                        "extractedUTF16Length": "\(extractedText.utf16.count)",
                        "fallbackUTF16Length": "\(textFallback.utf16.count)",
                    ]
                )
            )
        }

        return DocumentFileInspector.localFileSecurityMetadata(
            url: url,
            formatId: id,
            inspectionStatus: .partiallyInspected,
            isEncrypted: false,
            findings: findings,
            externalReferences: externalReferences,
            activeContentTypes: activeContentTypes
        )
    }

    // MARK: - Paths and IDs

    private static func numberedPart(path: String, prefix: String) -> Int? {
        guard path.hasPrefix(prefix), path.hasSuffix(".xml") else { return nil }
        let start = path.index(path.startIndex, offsetBy: prefix.count)
        let end = path.index(path.endIndex, offsetBy: -".xml".count)
        guard start < end else { return nil }
        return Int(path[start ..< end])
    }

    private static func relationshipsPart(for sourcePart: String) -> String {
        var components = sourcePart.split(separator: "/").map(String.init)
        guard let fileName = components.popLast() else { return "\(sourcePart).rels" }
        components.append("_rels")
        components.append("\(fileName).rels")
        return components.joined(separator: "/")
    }

    private static func resolveRelationshipTarget(from sourcePart: String, target: String) -> String? {
        guard !target.contains("\\") else { return nil }
        guard !isExternallyAddressedRelationshipTarget(target) else {
            return nil
        }

        let sourceDirectory = sourcePart.split(separator: "/").dropLast().map(String.init)
        let targetComponents = target.split(separator: "/").map(String.init)
        let rawComponents = target.hasPrefix("/") ? targetComponents : sourceDirectory + targetComponents
        var normalized: [String] = []
        for component in rawComponents {
            switch component {
            case "", ".":
                continue
            case "..":
                guard !normalized.isEmpty else { return nil }
                normalized.removeLast()
            default:
                normalized.append(component)
            }
        }
        return normalized.joined(separator: "/")
    }

    private static func slideAnchorId(slideIndex: Int) -> String {
        "presentation/slide-\(slideIndex + 1)"
    }

    private static func notesAnchorId(slideIndex: Int) -> String {
        "\(slideAnchorId(slideIndex: slideIndex))/speaker-notes"
    }

    private static func paragraphAnchorId(
        slideIndex: Int,
        region: PresentationTextRegion,
        paragraphIndex: Int
    ) -> String {
        "\(slideAnchorId(slideIndex: slideIndex))/\(region.idComponent)/p-\(paragraphIndex + 1)"
    }

    private static func textRunAnchorId(
        slideIndex: Int,
        region: PresentationTextRegion,
        paragraphIndex: Int,
        runIndex: Int
    ) -> String {
        "\(paragraphAnchorId(slideIndex: slideIndex, region: region, paragraphIndex: paragraphIndex))/r-\(runIndex + 1)"
    }

    private static func tableAnchorId(slideIndex: Int, tableIndex: Int) -> String {
        "\(slideAnchorId(slideIndex: slideIndex))/table-\(tableIndex + 1)"
    }

    private static func tableRowAnchorId(slideIndex: Int, tableIndex: Int, rowIndex: Int) -> String {
        "\(tableAnchorId(slideIndex: slideIndex, tableIndex: tableIndex))/row-\(rowIndex + 1)"
    }

    private static func tableCellAnchorId(
        slideIndex: Int,
        tableIndex: Int,
        rowIndex: Int,
        columnIndex: Int
    ) -> String {
        "\(tableRowAnchorId(slideIndex: slideIndex, tableIndex: tableIndex, rowIndex: rowIndex))/cell-\(columnIndex + 1)"
    }

    private static func anchorPath(
        slideIndex: Int,
        region: PresentationTextRegion,
        paragraphIndex: Int,
        runIndex: Int? = nil
    ) -> [DocumentAnchor.PathComponent] {
        var path: [DocumentAnchor.PathComponent] = [
            .init(kind: .document),
            .init(kind: .slide, index: slideIndex),
            .init(kind: region.anchorKind),
            .init(kind: .paragraph, index: paragraphIndex),
        ]
        if let runIndex {
            path.append(.init(kind: .run, index: runIndex))
        }
        return path
    }

    private static func tableAnchorPath(
        slideIndex: Int,
        tableIndex: Int,
        rowIndex: Int? = nil,
        columnIndex: Int? = nil
    ) -> [DocumentAnchor.PathComponent] {
        var path: [DocumentAnchor.PathComponent] = [
            .init(kind: .document),
            .init(kind: .slide, index: slideIndex),
            .init(kind: .table, index: tableIndex),
        ]
        if let rowIndex {
            path.append(.init(kind: .row, index: rowIndex))
        }
        if let columnIndex {
            path.append(.init(kind: .cell, index: columnIndex))
        }
        return path
    }

    private static func fileSize(for url: URL) throws -> Int64 {
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            if let size = values.fileSize {
                return Int64(size)
            }

            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            if let size = attributes[.size] as? NSNumber {
                return size.int64Value
            }
            return 0
        } catch {
            throw DocumentAdapterError.readFailed(underlying: error.localizedDescription)
        }
    }
}

private struct SlidePart: Sendable {
    let number: Int
    let path: String
}

private struct PresentationPartTextExtraction {
    let textRuns: [PresentationTextRun]
    let tables: [PresentationTable]
    let isHiddenSlide: Bool
}

private struct PresentationParagraphRuns {
    let index: Int
    let runs: [PresentationTextRun]
}

private struct ParagraphAppendResult {
    let elements: [DocumentElement]
    let textStart: Int
    let textEnd: Int
    let paragraphRanges: [Int: DocumentTextRange]
}

private enum PresentationTextRegion: String {
    case slideText
    case speakerNotes

    var idComponent: String {
        switch self {
        case .slideText: return "text"
        case .speakerNotes: return "speaker-notes"
        }
    }

    var label: String {
        switch self {
        case .slideText: return "text"
        case .speakerNotes: return "speaker notes"
        }
    }

    var sourceRegionName: String {
        switch self {
        case .slideText: return "slideText"
        case .speakerNotes: return "speakerNotes"
        }
    }

    var anchorKind: DocumentAnchor.Kind {
        switch self {
        case .slideText: return .text
        case .speakerNotes: return .speakerNotes
        }
    }
}

private enum Constants {
    static let maxEntries = 4_096
    static let maxXMLPartBytes = 5 * 1024 * 1024
    static let maxTextPartUTF16 = 1_000_000
    static let maxXMLDepth = 512
    static let maxRelationshipFiles = 512
}

private func isExternallyAddressedRelationshipTarget(_ target: String) -> Bool {
    let lowercased = target.lowercased()
    return lowercased.hasPrefix("http://")
        || lowercased.hasPrefix("https://")
        || lowercased.hasPrefix("file://")
        || lowercased.hasPrefix("//")
}

private struct OpenXMLRelationship: Sendable {
    enum TargetMode: Sendable {
        case internalPackage
        case external
    }

    let id: String
    let type: String
    let target: String
    let targetMode: TargetMode

    var isMacroProject: Bool {
        relationshipTypeName == "vbaproject" || target.lowercased().hasSuffix("vbaproject.bin")
    }

    var isEmbeddedObject: Bool {
        let lowercasedTarget = target.lowercased()
        return ["oleobject", "package", "control", "activexcontrol"].contains(relationshipTypeName)
            || lowercasedTarget.contains("/embeddings/")
            || lowercasedTarget.contains("/activex/")
            || lowercasedTarget.contains("/ctrlprops/")
    }

    var referenceKind: DocumentExternalReference.Kind {
        let lowercased = type.lowercased()
        if lowercased.contains("hyperlink") {
            return .hyperlink
        }
        if lowercased.contains("image") {
            return .image
        }
        if lowercased.contains("stylesheet") {
            return .stylesheet
        }
        if lowercased.contains("script") {
            return .script
        }
        if lowercased.contains("media") || lowercased.contains("audio") || lowercased.contains("video") {
            return .media
        }
        if lowercased.contains("attachedtemplate") || lowercased.contains("remotetemplate") {
            return .remoteTemplate
        }
        return .packageRelationship
    }

    private var relationshipTypeName: String {
        type.split(separator: "/").last.map { String($0).lowercased() } ?? ""
    }
}

private final class OpenXMLTextRunCollector: NSObject, XMLParserDelegate {
    private let maxUTF16Length: Int
    private var depth = 0
    private var inParagraph = false
    private var inText = false
    private var currentRun = ""
    private var currentParagraphRuns: [String] = []
    private var nextParagraphIndex = 0
    private var totalUTF16Length = 0
    private var tableDepth = 0
    private var inTableRow = false
    private var inTableCell = false
    private var currentTableRows: [CollectedTable.Row] = []
    private var currentRowCells: [CollectedTable.Cell] = []
    private var currentCellParagraphIndexes: [Int] = []
    private var currentCellParagraphTexts: [String] = []

    private(set) var runs: [CollectedRun] = []
    private(set) var tables: [CollectedTable] = []
    private(set) var didOverflow = false
    private(set) var didExceedDepth = false
    private(set) var isHiddenSlide = false

    init(maxUTF16Length: Int) {
        self.maxUTF16Length = maxUTF16Length
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        depth += 1
        if depth > Constants.maxXMLDepth {
            didExceedDepth = true
            parser.abortParsing()
            return
        }

        let localName = OpenXMLName.localName(elementName, qualifiedName: qName)
        if depth == 1, localName == "sld" {
            isHiddenSlide = OpenXMLBoolean.isFalse(OpenXMLName.attribute("show", in: attributeDict))
        }

        switch localName {
        case "tbl":
            tableDepth += 1
            if tableDepth == 1 {
                currentTableRows = []
            }
        case "tr":
            if tableDepth > 0, !inTableRow {
                inTableRow = true
                currentRowCells = []
            }
        case "tc":
            if tableDepth > 0, inTableRow, !inTableCell {
                inTableCell = true
                currentCellParagraphIndexes = []
                currentCellParagraphTexts = []
            }
        case "p":
            inParagraph = true
            currentParagraphRuns = []
        case "t":
            inText = true
            currentRun = ""
        default:
            break
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        defer { depth = max(0, depth - 1) }

        switch OpenXMLName.localName(elementName, qualifiedName: qName) {
        case "t":
            if !currentRun.isEmpty {
                if inParagraph {
                    currentParagraphRuns.append(currentRun)
                } else if let paragraph = appendParagraphRuns([currentRun], parser: parser),
                    inTableCell
                {
                    currentCellParagraphIndexes.append(paragraph.index)
                    currentCellParagraphTexts.append(paragraph.text)
                }
            }
            currentRun = ""
            inText = false
        case "p":
            if let paragraph = appendParagraphRuns(currentParagraphRuns, parser: parser),
                inTableCell
            {
                currentCellParagraphIndexes.append(paragraph.index)
                currentCellParagraphTexts.append(paragraph.text)
            }
            currentParagraphRuns = []
            inParagraph = false
        case "tc":
            if inTableCell {
                currentRowCells.append(
                    CollectedTable.Cell(
                        text: currentCellParagraphTexts.joined(separator: "\n"),
                        paragraphIndexes: currentCellParagraphIndexes
                    )
                )
                currentCellParagraphIndexes = []
                currentCellParagraphTexts = []
                inTableCell = false
            }
        case "tr":
            if inTableRow {
                currentTableRows.append(CollectedTable.Row(cells: currentRowCells))
                currentRowCells = []
                inTableRow = false
            }
        case "tbl":
            if tableDepth == 1 {
                tables.append(CollectedTable(rows: currentTableRows))
                currentTableRows = []
            }
            tableDepth = max(0, tableDepth - 1)
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard inText else { return }
        currentRun.append(string)
    }

    func parser(
        _ parser: XMLParser,
        resolveExternalEntityName name: String,
        systemID: String?
    ) -> Data? {
        nil
    }

    private func appendParagraphRuns(_ rawRuns: [String], parser: XMLParser) -> CollectedParagraph? {
        let paragraphText = rawRuns.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !paragraphText.isEmpty else { return nil }

        let paragraphIndex = nextParagraphIndex
        var runIndex = 0
        var collectedRuns: [CollectedRun] = []
        for rawRun in rawRuns {
            guard !rawRun.isEmpty else { continue }
            let nextTotal = totalUTF16Length + rawRun.utf16.count
            if nextTotal > maxUTF16Length {
                didOverflow = true
                parser.abortParsing()
                return nil
            }
            totalUTF16Length = nextTotal
            collectedRuns.append(
                CollectedRun(
                    text: rawRun,
                    paragraphIndex: paragraphIndex,
                    runIndex: runIndex
                )
            )
            runIndex += 1
        }
        guard !collectedRuns.isEmpty else { return nil }
        runs.append(contentsOf: collectedRuns)
        nextParagraphIndex += 1
        return CollectedParagraph(index: paragraphIndex, text: paragraphText)
    }

    struct CollectedParagraph {
        let index: Int
        let text: String
    }

    struct CollectedRun {
        let text: String
        let paragraphIndex: Int
        let runIndex: Int
    }

    struct CollectedTable {
        let rows: [Row]

        struct Row {
            let cells: [Cell]
        }

        struct Cell {
            let text: String
            let paragraphIndexes: [Int]
        }
    }
}

private final class OpenXMLSlideOrderCollector: NSObject, XMLParserDelegate {
    private(set) var relationshipIds: [String] = []

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard OpenXMLName.localName(elementName, qualifiedName: qName) == "sldId",
            let relationshipId = OpenXMLName.attribute("r:id", in: attributeDict)
        else {
            return
        }
        relationshipIds.append(relationshipId)
    }

    func parser(
        _ parser: XMLParser,
        resolveExternalEntityName name: String,
        systemID: String?
    ) -> Data? {
        nil
    }
}

private final class OpenXMLRelationshipCollector: NSObject, XMLParserDelegate {
    private(set) var relationships: [OpenXMLRelationship] = []

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard OpenXMLName.localName(elementName, qualifiedName: qName) == "Relationship",
            let id = OpenXMLName.attribute("Id", in: attributeDict),
            let type = OpenXMLName.attribute("Type", in: attributeDict),
            let target = OpenXMLName.attribute("Target", in: attributeDict)
        else {
            return
        }

        let mode =
            OpenXMLName.attribute("TargetMode", in: attributeDict)?.lowercased() == "external"
                || isExternallyAddressedRelationshipTarget(target)
            ? OpenXMLRelationship.TargetMode.external
            : .internalPackage
        relationships.append(
            OpenXMLRelationship(
                id: id,
                type: type,
                target: target,
                targetMode: mode
            )
        )
    }

    func parser(
        _ parser: XMLParser,
        resolveExternalEntityName name: String,
        systemID: String?
    ) -> Data? {
        nil
    }
}

private enum OpenXMLName {
    static func localName(_ elementName: String, qualifiedName qName: String?) -> String {
        let name = qName ?? elementName
        return name.split(separator: ":").last.map(String.init) ?? name
    }

    static func attribute(_ name: String, in attributes: [String: String]) -> String? {
        if let value = attributes[name] {
            return value
        }
        let lowercasedName = name.lowercased()
        return attributes.first { key, _ in
            key.split(separator: ":").last.map { $0.lowercased() } == lowercasedName
        }?.value
    }
}

private enum OpenXMLBoolean {
    static func isFalse(_ value: String?) -> Bool {
        guard let value else { return false }
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "0", "false":
            return true
        default:
            return false
        }
    }
}

private struct BoundedZipReader: Sendable {
    private let data: Data
    private let entriesByName: [String: ZipEntry]

    var entryNames: [String] {
        entriesByName.keys.sorted()
    }

    init(url: URL, maxArchiveBytes: Int) throws {
        let data = try Data(contentsOf: url)
        guard data.count <= maxArchiveBytes else {
            throw DocumentAdapterError.sizeLimitExceeded(
                actual: Int64(data.count),
                limit: Int64(maxArchiveBytes)
            )
        }
        self.data = data
        self.entriesByName = try Self.parseEntries(data: data)
    }

    func contains(_ path: String) -> Bool {
        entriesByName[path] != nil
    }

    func entryData(_ path: String, maxUncompressedBytes: Int) throws -> Data {
        guard let entry = entriesByName[path] else {
            throw DocumentAdapterError.readFailed(underlying: "ZIP entry \(path) was not found.")
        }
        guard entry.uncompressedSize <= maxUncompressedBytes else {
            throw DocumentAdapterError.readFailed(
                underlying: "ZIP entry \(path) exceeds the PPTX XML size limit."
            )
        }
        guard entry.compressedSize <= data.count else {
            throw DocumentAdapterError.readFailed(underlying: "ZIP entry \(path) has invalid compressed size.")
        }

        let localHeaderOffset = entry.localHeaderOffset
        guard localHeaderOffset + 30 <= data.count,
            Self.uint32(data, localHeaderOffset) == Signatures.localFileHeader
        else {
            throw DocumentAdapterError.readFailed(underlying: "ZIP entry \(path) has an invalid local header.")
        }

        let nameLength = Int(Self.uint16(data, localHeaderOffset + 26))
        let extraLength = Int(Self.uint16(data, localHeaderOffset + 28))
        let dataStart = localHeaderOffset + 30 + nameLength + extraLength
        let dataEnd = dataStart + entry.compressedSize
        guard dataStart <= data.count, dataEnd <= data.count else {
            throw DocumentAdapterError.readFailed(underlying: "ZIP entry \(path) points outside the archive.")
        }

        let localNameStart = localHeaderOffset + 30
        let localNameEnd = localNameStart + nameLength
        guard localNameEnd <= data.count,
            String(data: data[localNameStart ..< localNameEnd], encoding: .utf8) == path
        else {
            throw DocumentAdapterError.readFailed(underlying: "ZIP entry \(path) local header name mismatch.")
        }

        let compressed = data[dataStart ..< dataEnd]
        switch entry.compressionMethod {
        case 0:
            guard compressed.count == entry.uncompressedSize else {
                throw DocumentAdapterError.readFailed(underlying: "ZIP entry \(path) stored size mismatch.")
            }
            return Data(compressed)
        case 8:
            return try Self.inflate(compressed, outputSize: entry.uncompressedSize, path: path)
        default:
            throw DocumentAdapterError.readFailed(
                underlying: "ZIP entry \(path) uses unsupported compression method \(entry.compressionMethod)."
            )
        }
    }

    private static func parseEntries(data: Data) throws -> [String: ZipEntry] {
        guard data.count >= 22 else {
            throw DocumentAdapterError.readFailed(underlying: "ZIP archive is too small.")
        }

        let eocdOffset = try endOfCentralDirectoryOffset(in: data)
        let diskNumber = uint16(data, eocdOffset + 4)
        let centralDirectoryDisk = uint16(data, eocdOffset + 6)
        let entriesOnDisk = uint16(data, eocdOffset + 8)
        let totalEntries = uint16(data, eocdOffset + 10)
        let centralDirectorySize = uint32(data, eocdOffset + 12)
        let centralDirectoryOffset = uint32(data, eocdOffset + 16)
        guard diskNumber == 0, centralDirectoryDisk == 0, entriesOnDisk == totalEntries else {
            throw DocumentAdapterError.readFailed(underlying: "Multi-disk ZIP archives are not supported.")
        }
        guard totalEntries != UInt16.max,
            centralDirectorySize != UInt32.max,
            centralDirectoryOffset != UInt32.max
        else {
            throw DocumentAdapterError.readFailed(underlying: "ZIP64 PPTX packages are not supported.")
        }
        guard Int(totalEntries) <= Constants.maxEntries else {
            throw DocumentAdapterError.readFailed(underlying: "ZIP archive contains too many entries.")
        }

        let directoryOffset = Int(centralDirectoryOffset)
        let directorySize = Int(centralDirectorySize)
        guard directoryOffset >= 0,
            directorySize >= 0,
            directoryOffset + directorySize <= eocdOffset
        else {
            throw DocumentAdapterError.readFailed(underlying: "ZIP central directory is outside the archive.")
        }

        var offset = directoryOffset
        var entries: [String: ZipEntry] = [:]
        for _ in 0 ..< Int(totalEntries) {
            guard offset + 46 <= data.count,
                uint32(data, offset) == Signatures.centralDirectoryHeader
            else {
                throw DocumentAdapterError.readFailed(underlying: "ZIP central directory entry is invalid.")
            }

            let flags = uint16(data, offset + 8)
            let compressionMethod = uint16(data, offset + 10)
            let compressedSize = uint32(data, offset + 20)
            let uncompressedSize = uint32(data, offset + 24)
            let fileNameLength = Int(uint16(data, offset + 28))
            let extraLength = Int(uint16(data, offset + 30))
            let commentLength = Int(uint16(data, offset + 32))
            let localHeaderOffset = uint32(data, offset + 42)
            guard localHeaderOffset != UInt32.max,
                compressedSize != UInt32.max,
                uncompressedSize != UInt32.max
            else {
                throw DocumentAdapterError.readFailed(underlying: "ZIP64 PPTX entries are not supported.")
            }

            let nameStart = offset + 46
            let nameEnd = nameStart + fileNameLength
            let nextOffset = nameEnd + extraLength + commentLength
            guard nameEnd <= data.count, nextOffset <= data.count else {
                throw DocumentAdapterError.readFailed(underlying: "ZIP central directory entry is truncated.")
            }
            guard let path = String(data: data[nameStart ..< nameEnd], encoding: .utf8),
                isSafeEntryPath(path)
            else {
                throw DocumentAdapterError.readFailed(underlying: "ZIP archive contains an unsafe entry path.")
            }
            guard flags & 0x0001 == 0 else {
                throw DocumentAdapterError.readFailed(underlying: "Encrypted ZIP entries are not supported.")
            }
            guard compressionMethod == 0 || compressionMethod == 8 else {
                throw DocumentAdapterError.readFailed(
                    underlying: "ZIP entry \(path) uses unsupported compression method \(compressionMethod)."
                )
            }
            guard entries[path] == nil else {
                throw DocumentAdapterError.readFailed(underlying: "ZIP archive contains duplicate entry \(path).")
            }

            entries[path] = ZipEntry(
                path: path,
                compressionMethod: compressionMethod,
                compressedSize: Int(compressedSize),
                uncompressedSize: Int(uncompressedSize),
                localHeaderOffset: Int(localHeaderOffset)
            )
            offset = nextOffset
        }

        return entries
    }

    private static func endOfCentralDirectoryOffset(in data: Data) throws -> Int {
        let minimumOffset = max(0, data.count - 22 - UInt16.maxValueAsInt)
        var offset = data.count - 22
        while offset >= minimumOffset {
            if uint32(data, offset) == Signatures.endOfCentralDirectory {
                let commentLength = Int(uint16(data, offset + 20))
                if offset + 22 + commentLength == data.count {
                    return offset
                }
            }
            offset -= 1
        }
        throw DocumentAdapterError.readFailed(underlying: "ZIP end-of-central-directory record was not found.")
    }

    private static func inflate(_ compressed: Data, outputSize: Int, path: String) throws -> Data {
        if outputSize == 0 {
            return Data()
        }
        var output = [UInt8](repeating: 0, count: outputSize)
        let written = compressed.withUnsafeBytes { sourceBuffer in
            guard let source = sourceBuffer.bindMemory(to: UInt8.self).baseAddress else {
                return 0
            }
            return compression_decode_buffer(
                &output,
                output.count,
                source,
                compressed.count,
                nil,
                COMPRESSION_ZLIB
            )
        }
        guard written == outputSize else {
            throw DocumentAdapterError.readFailed(underlying: "ZIP entry \(path) could not be inflated.")
        }
        return Data(output)
    }

    private static func isSafeEntryPath(_ path: String) -> Bool {
        guard !path.isEmpty,
            !path.hasPrefix("/"),
            !path.contains("\\"),
            !path.contains("\0")
        else {
            return false
        }
        return !path.split(separator: "/").contains("..")
    }

    private static func uint16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private static func uint32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset])
            | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16
            | UInt32(data[offset + 3]) << 24
    }
}

private struct ZipEntry: Sendable {
    let path: String
    let compressionMethod: UInt16
    let compressedSize: Int
    let uncompressedSize: Int
    let localHeaderOffset: Int
}

private enum Signatures {
    static let localFileHeader: UInt32 = 0x0403_4B50
    static let centralDirectoryHeader: UInt32 = 0x0201_4B50
    static let endOfCentralDirectory: UInt32 = 0x0605_4B50
}

private extension UInt16 {
    static let maxValueAsInt = Int(UInt16.max)
}
