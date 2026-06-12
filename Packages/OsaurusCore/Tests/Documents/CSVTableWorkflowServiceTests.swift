//
//  CSVTableWorkflowServiceTests.swift
//  osaurusTests
//
//  Covers CSV/TSV workflow previews and explicit delimited-text export.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("CSV table workflow service")
struct CSVTableWorkflowServiceTests {
    @Test func previewInfersHeaderSchemaAndSamples() async throws {
        let url = try Self.write(
            """
            name,age,active,joined
            Ada,37,true,2026-06-05
            Ben,41,false,2026-06-06
            """,
            filename: "people.csv"
        )
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try await CSVAdapter(delimiter: .comma).parse(url: url, sizeLimit: 0)

        let preview = try CSVTableWorkflowService.preview(document)

        #expect(preview.hasHeader)
        #expect(preview.columnCount == 4)
        #expect(preview.sampledRowCount == 3)
        #expect(preview.columns.map(\.name) == ["name", "age", "active", "joined"])
        #expect(preview.columns.map(\.inferredType) == [.string, .integer, .boolean, .date])
        #expect(preview.columns[1].nonEmptyCount == 2)
        #expect(preview.columns[1].sampleValues == ["37", "41"])
    }

    @Test func previewFromLargeFileRespectsByteRowAndColumnCaps() async throws {
        let rows = (0 ..< 200).map { "row\($0),\($0),\($0 * 2)" }.joined(separator: "\n")
        let url = try Self.write("name,value,extra\n\(rows)", filename: "large.csv")
        defer { try? FileManager.default.removeItem(at: url) }

        let preview = try await CSVTableWorkflowService.preview(
            url: url,
            delimiter: .comma,
            policy: CSVTablePreviewPolicy(
                maxPreviewBytes: 128,
                maxRows: 3,
                maxColumns: 2,
                maxSampleValuesPerColumn: 2,
                maxCellPreviewUTF16Units: 16
            )
        )

        #expect(preview.truncatedByByteLimit)
        #expect(preview.truncatedByRowLimit)
        #expect(preview.truncatedByColumnLimit)
        #expect(preview.rowsScanned == 3)
        #expect(preview.columnCount == 2)
        #expect(preview.columns.map(\.name) == ["name", "value"])
    }

    @Test func exportConvertsCSVToTSVAndRoundTrips() async throws {
        let source = try Self.write("name,note\nAda,\"Hello, world\"\n", filename: "notes.csv")
        let target = Self.temporaryURL(extension: "tsv")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: target)
        }
        let document = try await CSVAdapter(delimiter: .comma).parse(url: source, sizeLimit: 0)

        let result = try await CSVTableWorkflowService.export(
            document,
            to: target,
            delimiter: .tab
        )

        #expect(result.formatId == "tsv")
        #expect(result.bytesWritten > 0)
        let parsed = try await CSVAdapter(delimiter: .tab).parse(url: target, sizeLimit: 0)
        let table = try #require(parsed.representation.underlying as? CSVDocument)
        #expect(table.delimiter == .tab)
        #expect(table.rows[1].cells.map(\.text) == ["Ada", "Hello, world"])
    }

    @Test func exportRejectsFormulaLikeCellsWithoutTouchingTarget() async throws {
        let source = try Self.write("name,value\nAda,=2+2\n", filename: "formula.csv")
        let target = Self.temporaryURL(extension: "csv")
        try "existing".write(to: target, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: target)
        }
        let document = try await CSVAdapter(delimiter: .comma).parse(url: source, sizeLimit: 0)

        do {
            _ = try await CSVTableWorkflowService.export(document, to: target, delimiter: .comma)
            Issue.record("expected formula-like export validation failure")
        } catch CSVTableWorkflowError.validationFailed(let issues) {
            #expect(issues.map(\.code).contains(.formulaLikeText))
            #expect(try String(contentsOf: target, encoding: .utf8) == "existing")
        } catch {
            Issue.record("expected formula-like export validation failure, got \(error)")
        }
    }

    @Test func emitterRejectsFormulaLikeCellsByDefault() async throws {
        let source = try Self.write("name,value\nAda,@cmd\n", filename: "formula.csv")
        let target = Self.temporaryURL(extension: "csv")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: target)
        }
        let document = try await CSVAdapter(delimiter: .comma).parse(url: source, sizeLimit: 0)

        await #expect(throws: DocumentAdapterError.self) {
            try await CSVEmitter(delimiter: .comma).emit(document, to: target)
        }
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    private static func write(_ content: String, filename: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-\(filename)")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func temporaryURL(extension ext: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-table-workflow.\(ext)")
    }
}
