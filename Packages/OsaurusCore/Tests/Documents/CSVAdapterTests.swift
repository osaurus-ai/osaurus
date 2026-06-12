//
//  CSVAdapterTests.swift
//  osaurusTests
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("CSVAdapter")
struct CSVAdapterTests {
    @Test func canHandle_acceptsCSVAndTSVExtensions() {
        let csv = CSVAdapter(delimiter: .comma)
        let tsv = CSVAdapter(delimiter: .tab)

        #expect(csv.canHandle(url: URL(fileURLWithPath: "/tmp/table.csv"), uti: nil))
        #expect(csv.canHandle(url: URL(fileURLWithPath: "/tmp/table.CSV"), uti: nil))
        #expect(csv.canHandle(url: URL(fileURLWithPath: "/tmp/table.tsv"), uti: nil) == false)
        #expect(tsv.canHandle(url: URL(fileURLWithPath: "/tmp/table.tsv"), uti: nil))
        #expect(tsv.canHandle(url: URL(fileURLWithPath: "/tmp/table.csv"), uti: nil) == false)
    }

    @Test func parse_readsCommaCSVRowsAndCells() async throws {
        let url = try Self.write("name,age\nAda,37\n", filename: "people.csv")
        defer { try? FileManager.default.removeItem(at: url) }

        let doc = try await CSVAdapter(delimiter: .comma).parse(url: url, sizeLimit: 0)
        let csv = try #require(doc.representation.underlying as? CSVDocument)

        #expect(doc.formatId == "csv")
        #expect(csv.delimiter == .comma)
        #expect(csv.rowCount == 2)
        #expect(csv.columnCount == 2)
        #expect(csv.rows[0].cells.map(\.text) == ["name", "age"])
        #expect(csv.rows[1].cells.map(\.text) == ["Ada", "37"])
        #expect(doc.textFallback == "name\tage\nAda\t37")
        #expect(doc.security.inspectionStatus == .inspected)
        #expect(doc.security.sha256?.isEmpty == false)
    }

    @Test func parse_readsTSVWithTabDelimiter() async throws {
        let url = try Self.write("name\trole\nAda\tengineer", filename: "people.tsv")
        defer { try? FileManager.default.removeItem(at: url) }

        let doc = try await CSVAdapter(delimiter: .tab).parse(url: url, sizeLimit: 0)
        let csv = try #require(doc.representation.underlying as? CSVDocument)

        #expect(doc.formatId == "tsv")
        #expect(csv.delimiter == .tab)
        #expect(csv.rows[1].cells.map(\.text) == ["Ada", "engineer"])
        #expect(doc.textFallback == "name\trole\nAda\tengineer")
    }

    @Test func parse_unescapesQuotedFieldsAndEscapedQuotes() async throws {
        let source = "name,quote\nAda,\"Hello, \"\"world\"\"\"\n"
        let url = try Self.write(source, filename: "quotes.csv")
        defer { try? FileManager.default.removeItem(at: url) }

        let doc = try await CSVAdapter(delimiter: .comma).parse(url: url, sizeLimit: 0)
        let csv = try #require(doc.representation.underlying as? CSVDocument)
        let quoteCell = csv.rows[1].cells[1]

        #expect(quoteCell.text == "Hello, \"world\"")
        #expect(quoteCell.wasQuoted)
        #expect(quoteCell.sourceRange.length == "\"Hello, \"\"world\"\"\"".utf16.count)
        #expect(doc.textFallback == "name\tquote\nAda\tHello, \"world\"")
    }

    @Test func parse_preservesCRLFAndBlankLinesAsRows() async throws {
        let url = try Self.write("a,b\r\n\r\nc,d", filename: "blank-lines.csv")
        defer { try? FileManager.default.removeItem(at: url) }

        let doc = try await CSVAdapter(delimiter: .comma).parse(url: url, sizeLimit: 0)
        let csv = try #require(doc.representation.underlying as? CSVDocument)

        #expect(csv.rows.count == 3)
        #expect(csv.rows[1].cells.count == 1)
        #expect(csv.rows[1].cells[0].text == "")
        #expect(csv.rows[1].sourceRange.length == 0)
        #expect(doc.textFallback == "a\tb\n\nc\td")
    }

    @Test func parse_buildsFallbackTextAndStructureAnchors() async throws {
        let url = try Self.write("A😀,B\nC,D", filename: "anchors.csv")
        defer { try? FileManager.default.removeItem(at: url) }

        let doc = try await CSVAdapter(delimiter: .comma).parse(url: url, sizeLimit: 0)
        let csv = try #require(doc.representation.underlying as? CSVDocument)
        let firstCell = csv.rows[0].cells[0]
        let secondRowAnchor = try #require(doc.structure.anchor(id: "document/table/rows/1"))
        let firstCellAnchor = try #require(doc.structure.anchor(id: firstCell.anchorId))

        #expect(doc.structure.elements(kind: .table).count == 1)
        #expect(doc.structure.elements(kind: .tableRow).count == 2)
        #expect(doc.structure.elements(kind: .tableCell).count == 4)
        #expect(firstCell.textRange == DocumentTextRange(startUTF16Offset: 0, length: "A😀".utf16.count))
        #expect(firstCell.sourceRange == DocumentTextRange(startUTF16Offset: 0, length: "A😀".utf16.count))
        #expect(firstCellAnchor.sourceRange?.start.rowIndex == 0)
        #expect(firstCellAnchor.sourceRange?.start.columnIndex == 0)
        #expect(firstCellAnchor.textRange == firstCell.textRange)
        #expect(secondRowAnchor.textRange?.startUTF16Offset == "A😀\tB\n".utf16.count)
        #expect(doc.structure.textLengthUTF16 == doc.textFallback.utf16.count)
    }

    @Test func parse_throwsSizeLimitExceededAboveCap() async throws {
        let url = try Self.write("a,b", filename: "too-large.csv")
        defer { try? FileManager.default.removeItem(at: url) }

        await #expect(throws: DocumentAdapterError.self) {
            _ = try await CSVAdapter(delimiter: .comma).parse(url: url, sizeLimit: 1)
        }
    }

    @Test func parse_throwsEmptyContentForEmptyFile() async throws {
        let url = try Self.write("", filename: "empty.csv")
        defer { try? FileManager.default.removeItem(at: url) }

        await #expect(throws: DocumentAdapterError.self) {
            _ = try await CSVAdapter(delimiter: .comma).parse(url: url, sizeLimit: 0)
        }
    }

    @Test func formatAdapter_opensDocumentAndStreamsRows() async throws {
        let url = try Self.write("name,age\nAda,37\n", filename: "people.csv")
        defer { try? FileManager.default.removeItem(at: url) }
        let adapter = CSVAdapter(delimiter: .comma)
        let reference = try adapter.openDocument(at: url)
        let (stream, continuation) = Self.makeRecordStream()

        let task = Task {
            try await adapter.streamRecords(into: continuation)
        }

        var records: [Record] = []
        for await record in stream {
            records.append(record)
        }
        try await task.value

        #expect(reference.formatIdentifier == "csv")
        #expect(reference.displayName.hasSuffix("people.csv"))
        #expect(records.map(\.fields) == [["name", "age"], ["Ada", "37"]])
        #expect(records[1].text == "Ada\t37")
        #expect(records[1].metadata["documentId"] == reference.id.uuidString)
    }

    @Test func bootstrap_registersCSVEmitters() async throws {
        let url = try Self.write("name,age\nAda,37\n", filename: "people.csv")
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try await CSVAdapter(delimiter: .comma).parse(url: url, sizeLimit: 0)
        let registry = DocumentFormatRegistry()

        DocumentAdaptersBootstrap.registerBuiltIns(registry: registry)

        #expect(registry.emitter(for: document)?.formatId == "csv")
    }

    private static func write(_ content: String, filename: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-\(filename)")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func makeRecordStream() -> (
        stream: AsyncStream<Record>,
        continuation: AsyncStream<Record>.Continuation
    ) {
        var continuation: AsyncStream<Record>.Continuation?
        let stream = AsyncStream<Record> { continuation = $0 }
        return (stream, continuation!)
    }
}
