//
//  DelimitedTextAdapterTests.swift
//  OsaurusStatsPackTests
//

import Foundation
import Testing

@testable import OsaurusStatsPack

@Suite("Delimited stats adapters")
struct DelimitedTextAdapterTests {
    @Test func csvWithSchema_streamsRowsWithSidecarMetadata() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let csvURL = directory.appendingPathComponent("people.csv")
        try "name,score\nAda,98.5\n".write(to: csvURL, atomically: true, encoding: .utf8)
        try """
        { "columns": [{ "name": "name", "type": "string" }, { "name": "score", "type": "float" }] }
        """.write(
            to: directory.appendingPathComponent("people.csvschema"),
            atomically: true,
            encoding: .utf8
        )

        let adapter = CSVWithSchemaAdapter()
        let reference = try adapter.openDocument(at: csvURL)
        let records = try await TestHelpers.collectRecords(from: adapter)

        #expect(reference.metadata["schemaSidecar"] == "true")
        #expect(reference.metadata["schemaColumnNames"] == "name\tscore")
        #expect(records.map(\.fields) == [["name", "score"], ["Ada", "98.5"]])
        #expect(records[0].metadata["rowKind"] == "header")
        #expect(records[1].metadata["headerColumnNames"] == "name\tscore")
        #expect(records[1].metadata["schemaColumnTypes"] == "string\tfloat")
    }

    @Test func csvWithSchema_withoutSidecarStillStreamsRows() async throws {
        let url = try TestHelpers.write("city,count\nParis,3\n", filename: "cities.csv")
        defer { try? FileManager.default.removeItem(at: url) }

        let adapter = CSVWithSchemaAdapter()
        let reference = try adapter.openDocument(at: url)
        let records = try await TestHelpers.collectRecords(from: adapter)

        #expect(reference.metadata["schemaSidecar"] == "false")
        #expect(reference.metadata["delimiter"] == "comma")
        #expect(records[1].fields == ["Paris", "3"])
        #expect(records[1].metadata["rowKind"] == "data")
        #expect(records[1].metadata["columnCount"] == "2")
    }

    @Test func csvWithSchema_unescapesQuotedFields() async throws {
        let url = try TestHelpers.write("name,quote\nAda,\"hi, \"\"team\"\"\"\n", filename: "quotes.csv")
        defer { try? FileManager.default.removeItem(at: url) }

        let adapter = CSVWithSchemaAdapter()
        _ = try adapter.openDocument(at: url)
        let records = try await TestHelpers.collectRecords(from: adapter)

        #expect(records[1].fields == ["Ada", "hi, \"team\""])
    }

    @Test func csvWithSchema_treatsFirstRowAsDataWhenSchemaNamesDoNotMatch() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let csvURL = directory.appendingPathComponent("measurements.csv")
        try "Ada,98.5\n".write(to: csvURL, atomically: true, encoding: .utf8)
        try """
        { "columns": [{ "name": "name", "type": "string" }, { "name": "score", "type": "float" }] }
        """.write(
            to: directory.appendingPathComponent("measurements.csvschema"),
            atomically: true,
            encoding: .utf8
        )

        let adapter = CSVWithSchemaAdapter()
        _ = try adapter.openDocument(at: csvURL)
        let records = try await TestHelpers.collectRecords(from: adapter)

        #expect(records[0].fields == ["Ada", "98.5"])
        #expect(records[0].metadata["rowKind"] == "data")
        #expect(records[0].metadata["headerColumnNames"] == nil)
        #expect(records[0].metadata["schemaColumnNames"] == "name\tscore")
    }

    @Test func tsv_streamsTabDelimitedRows() async throws {
        let url = try TestHelpers.write("name\trole\nAda\tengineer\n", filename: "people.tsv")
        defer { try? FileManager.default.removeItem(at: url) }

        let adapter = TSVStatsAdapter()
        let reference = try adapter.openDocument(at: url)
        let records = try await TestHelpers.collectRecords(from: adapter)

        #expect(reference.metadata["delimiter"] == "tab")
        #expect(reference.metadata["schemaSidecar"] == "false")
        #expect(records[1].fields == ["Ada", "engineer"])
        #expect(records[1].metadata["headerColumnNames"] == "name\trole")
    }

    @Test func tsv_preservesEmptyCells() async throws {
        let url = try TestHelpers.write("left\t\tmiddle\n", filename: "empty.tsv")
        defer { try? FileManager.default.removeItem(at: url) }

        let adapter = TSVStatsAdapter()
        _ = try adapter.openDocument(at: url)
        let records = try await TestHelpers.collectRecords(from: adapter)

        #expect(records[0].fields == ["left", "", "middle"])
    }

    @Test func tsvWithSchema_streamsRowsWithSidecarMetadata() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let tsvURL = directory.appendingPathComponent("samples.tsv")
        try "sample\tvalue\nrun-1\t42\n".write(to: tsvURL, atomically: true, encoding: .utf8)
        try """
        { "columns": [{ "name": "sample", "type": "string" }, { "name": "value" }] }
        """.write(
            to: directory.appendingPathComponent("samples.tsvschema"),
            atomically: true,
            encoding: .utf8
        )

        let adapter = TSVStatsAdapter()
        let reference = try adapter.openDocument(at: tsvURL)
        let records = try await TestHelpers.collectRecords(from: adapter)

        #expect(reference.metadata["schemaSidecar"] == "true")
        #expect(reference.metadata["schemaColumnNames"] == "sample\tvalue")
        #expect(reference.metadata["schemaColumnTypes"] == "string\t")
        #expect(records[0].metadata["rowKind"] == "header")
        #expect(records[1].metadata["schemaSidecar"] == "true")
        #expect(records[1].fields == ["run-1", "42"])
    }

    @Test func tsv_rejectsWrongExtension() throws {
        let adapter = TSVStatsAdapter()

        #expect(throws: Error.self) {
            _ = try adapter.openDocument(at: URL(fileURLWithPath: "/tmp/not-tsv.csv"))
        }
    }
}
