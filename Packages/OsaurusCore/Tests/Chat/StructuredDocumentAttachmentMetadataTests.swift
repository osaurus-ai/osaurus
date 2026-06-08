//
//  StructuredDocumentAttachmentMetadataTests.swift
//  osaurusTests
//
//  Verifies that typed document parses keep their cheap routing metadata
//  on the attachment without changing the legacy text-document surface.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Structured document attachment metadata", .serialized)
struct StructuredDocumentAttachmentMetadataTests {
    private static let fixtureFormatId = "test-structured-attachment"
    private static let fixtureExtension = "structuredattachment"
    private static let createdAt = Date(timeIntervalSince1970: 1_783_939_200)

    @Test func factoryKeepsLegacyDocumentFallback() {
        let document = Self.sampleStructuredDocument(filename: "report.csv", text: "a,b\n1,2\n")
        let attachment = Attachment.structuredDocument(document)

        #expect(attachment.isDocument)
        #expect(attachment.filename == "report.csv")
        #expect(attachment.documentContent == "a,b\n1,2\n")
        #expect(attachment.loadDocumentContent() == "a,b\n1,2\n")

        guard case .document(let filename, let content, let fileSize) = attachment.kind else {
            Issue.record("structured document should keep using the legacy document attachment kind")
            return
        }

        #expect(filename == "report.csv")
        #expect(content == "a,b\n1,2\n")
        #expect(fileSize == Int(document.fileSize))
        #expect(attachment.structuredDocumentMetadata?.formatId == "csv")
        #expect(attachment.structuredDocumentMetadata?.representationFormatId == "csv")
        #expect(attachment.businessDocumentSummary?.kind == .table)
        #expect(attachment.businessDocumentSummary?.chipDetailLabel == "Table - \(Self.formattedBytes(42))")
    }

    @Test func metadataSurvivesCodableRoundTrip() throws {
        let attachment = Attachment.structuredDocument(
            Self.sampleStructuredDocument(filename: "ledger.csv", text: "debit,credit", fileSize: 128)
        )

        let encoded = try JSONEncoder().encode(attachment)
        let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] ?? [:]
        let kind = object["kind"] as? [String: Any] ?? [:]
        let metadata = object["structuredDocumentMetadata"] as? [String: Any] ?? [:]

        #expect(kind["type"] as? String == "document")
        #expect(kind["content"] as? String == "debit,credit")
        #expect(metadata["formatId"] as? String == "csv")
        #expect(metadata["documentKind"] as? String == "table")

        let decoded = try JSONDecoder().decode(Attachment.self, from: encoded)
        #expect(decoded.documentContent == "debit,credit")
        #expect(decoded.structuredDocumentMetadata == attachment.structuredDocumentMetadata)
    }

    @Test func legacyDocumentDecodesWithoutMetadata() throws {
        let json = """
            {
              "id": "00000000-0000-0000-0000-000000000001",
              "kind": {
                "type": "document",
                "filename": "notes.txt",
                "content": "plain fallback",
                "fileSize": 14
              }
            }
            """

        let decoded = try JSONDecoder().decode(Attachment.self, from: Data(json.utf8))
        #expect(decoded.documentContent == "plain fallback")
        #expect(decoded.structuredDocumentMetadata == nil)
    }

    @Test func legacyDocumentStillGetsDisplaySummaryFromExtension() {
        let attachment = Attachment.document(
            filename: "Budget.Q4.xlsx",
            content: "fallback",
            fileSize: 2_048
        )

        let summary = attachment.businessDocumentSummary
        #expect(summary?.kind == .workbook)
        #expect(summary?.isStructured == false)
        #expect(summary?.chipDetailLabel == "Workbook - \(Self.formattedBytes(2_048))")
        #expect(attachment.fileIcon == "tablecells")
    }

    @Test func metadataCapturesStructureAndSecurityFacts() {
        let security = DocumentSecurityMetadata(
            inspectionStatus: .partiallyInspected,
            formatId: "xlsx",
            fileExtension: "xlsx",
            activeContentTypes: [.formula],
            findings: [
                DocumentSecurityFinding(
                    kind: .formula,
                    severity: .medium,
                    message: "Workbook contains formulas."
                )
            ]
        )
        let document = Self.sampleStructuredDocument(
            formatId: "xlsx",
            filename: "budget.xlsx",
            text: "A1,B1",
            fileSize: 4096,
            structure: Self.workbookStructure(),
            security: security
        )
        let attachment = Attachment.structuredDocument(document)

        let metadata = attachment.structuredDocumentMetadata
        #expect(metadata?.fileExtension == "xlsx")
        #expect(metadata?.documentKind == .workbook)
        #expect(metadata?.inspectionStatus == .partiallyInspected)
        #expect(metadata?.maximumSeverity == .medium)
        #expect(metadata?.hasActiveContent == true)
        #expect(metadata?.structureSummary?.sheetCount == 1)
        #expect(metadata?.structureSummary?.tableCount == 1)
        #expect(
            attachment.businessDocumentSummary?.chipDetailLabel
                == "Workbook - 1 sheet - Review - \(Self.formattedBytes(4_096))"
        )
    }

    @Test func parseAllAttachesMetadataFromRegistryAdapter() throws {
        DocumentFormatRegistry.shared.register(
            adapter: FixtureAdapter(
                formatId: Self.fixtureFormatId,
                extensions: [Self.fixtureExtension],
                createdAt: Self.createdAt
            )
        )
        defer { DocumentFormatRegistry.shared.unregisterAll(formatId: Self.fixtureFormatId) }

        let url = try writeFile(content: "ignored", ext: Self.fixtureExtension)
        defer { try? FileManager.default.removeItem(at: url) }

        let attachments = try DocumentParser.parseAll(url: url)
        let metadata = attachments.first?.structuredDocumentMetadata

        #expect(attachments.first?.documentContent == "typed fallback")
        #expect(metadata?.formatId == Self.fixtureFormatId)
        #expect(metadata?.representationFormatId == Self.fixtureFormatId)
        #expect(metadata?.filename == url.lastPathComponent)
        #expect(metadata?.createdAt == Self.createdAt)
    }

    private func writeFile(content: String, ext: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-structured-attachment-\(UUID().uuidString).\(ext)")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func formattedBytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    private static func sampleStructuredDocument(
        formatId: String = "csv",
        filename: String = "sample.csv",
        text: String = "sample text",
        fileSize: Int64 = 42,
        structure: DocumentStructure? = nil,
        security: DocumentSecurityMetadata? = nil
    ) -> StructuredDocument {
        StructuredDocument(
            formatId: formatId,
            filename: filename,
            fileSize: fileSize,
            representation: AnyStructuredRepresentation(
                formatId: formatId,
                underlying: PlainTextRepresentation(text: text)
            ),
            structure: structure,
            security: security,
            textFallback: text,
            createdAt: createdAt
        )
    }

    private static func workbookStructure() -> DocumentStructure {
        let rootAnchor = DocumentAnchor.root(label: "budget.xlsx")
        let sheetAnchor = DocumentAnchor(
            kind: .sheet,
            path: [.init(kind: .document), .init(kind: .sheet, identifier: "Sheet1")]
        )
        let tableAnchor = DocumentAnchor(
            kind: .table,
            path: [
                .init(kind: .document),
                .init(kind: .sheet, identifier: "Sheet1"),
                .init(kind: .table, identifier: "A1:B2"),
            ]
        )
        let table = DocumentElement(kind: .table, anchor: tableAnchor)
        let sheet = DocumentElement(kind: .sheet, anchor: sheetAnchor, children: [table])
        let root = DocumentElement(kind: .document, anchor: rootAnchor, children: [sheet])
        return DocumentStructure(root: root, textLengthUTF16: 5)
    }

    private struct FixtureAdapter: DocumentFormatAdapter {
        let formatId: String
        let extensions: Set<String>
        let createdAt: Date

        func canHandle(url: URL, uti: String?) -> Bool {
            extensions.contains(url.pathExtension.lowercased())
        }

        func parse(url: URL, sizeLimit: Int64) async throws -> StructuredDocument {
            StructuredDocument(
                formatId: formatId,
                filename: url.lastPathComponent,
                fileSize: 15,
                representation: AnyStructuredRepresentation(
                    formatId: formatId,
                    underlying: PlainTextRepresentation(text: "typed fallback")
                ),
                textFallback: "typed fallback",
                createdAt: createdAt
            )
        }
    }
}
