//
//  SQLiteReadOnlyAdapterTests.swift
//  OsaurusStatsPackTests
//

import Foundation
import Testing

import OsaurusCore

@testable import OsaurusStatsPack

@Suite("SQLiteReadOnlyAdapter")
struct SQLiteReadOnlyAdapterTests {
    @Test func streamsRowsFromUserTables() async throws {
        let url = try TestHelpers.writeSQLiteFixture()
        defer { try? FileManager.default.removeItem(at: url) }

        let adapter = SQLiteReadOnlyAdapter()
        let reference = try adapter.openDocument(at: url)
        let records = try await TestHelpers.collectRecords(from: adapter)

        #expect(reference.metadata["mode"] == "read-only")
        #expect(records.contains { $0.metadata["table"] == "people" && $0.fields.contains("Ada") })
        #expect(records.contains { $0.metadata["table"] == "notes" && $0.fields == ["hello"] })
    }

    @Test func acceptsDBExtensionForSQLiteFiles() async throws {
        let url = try TestHelpers.writeSQLiteFixture(extension: "db")
        defer { try? FileManager.default.removeItem(at: url) }

        let adapter = SQLiteReadOnlyAdapter()
        _ = try adapter.openDocument(at: url)
        let records = try await TestHelpers.collectRecords(from: adapter)

        #expect(records.isEmpty == false)
    }

    @Test func streamsRowsWithoutPhysicalPathMetadata() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = try TestHelpers.writeSQLiteFixture(in: directory)
        let adapter = SQLiteReadOnlyAdapter()
        let reference = try adapter.openDocument(at: url)
        let records = try await TestHelpers.collectRecords(from: adapter)
        let metadataValues =
            Array(reference.metadata.values)
            + records.flatMap { Array($0.metadata.values) }

        #expect(reference.displayName == url.lastPathComponent)
        #expect(metadataValues.allSatisfy { !$0.contains(url.path) })
        #expect(metadataValues.allSatisfy { !$0.contains(directory.path) })
        #expect(records.allSatisfy { $0.anchorIdentifier?.contains(url.path) != true })
    }

    @Test func registryDetectsSQLiteMagicBytes() throws {
        let registry = FormatAdapterRegistry()
        try registry.register(SQLiteReadOnlyAdapter.self) { SQLiteReadOnlyAdapter() }
        let url = try TestHelpers.writeSQLiteFixture()
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(try registry.adapter(detecting: url) is SQLiteReadOnlyAdapter)
    }

    @Test func invalidSQLiteFileThrowsWhenStreaming() async throws {
        let url = try TestHelpers.write("not sqlite", filename: "bad.sqlite")
        defer { try? FileManager.default.removeItem(at: url) }

        let adapter = SQLiteReadOnlyAdapter()
        _ = try adapter.openDocument(at: url)

        await #expect(throws: SQLiteReadOnlyRecordStreamerError.self) {
            _ = try await TestHelpers.collectRecords(from: adapter)
        }
    }

    @Test func invalidSQLiteErrorsRemainPathFree() async throws {
        let url = try TestHelpers.write("not sqlite", filename: "bad.sqlite")
        defer { try? FileManager.default.removeItem(at: url) }

        let adapter = SQLiteReadOnlyAdapter()
        _ = try adapter.openDocument(at: url)

        do {
            _ = try await TestHelpers.collectRecords(from: adapter)
            Issue.record("Expected invalid SQLite streaming to fail")
        } catch {
            #expect(error.localizedDescription.contains(url.path) == false)
            #expect(error.localizedDescription.contains(url.deletingLastPathComponent().path) == false)
        }
    }
}
