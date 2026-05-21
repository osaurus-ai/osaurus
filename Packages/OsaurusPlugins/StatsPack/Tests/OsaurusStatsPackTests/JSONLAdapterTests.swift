//
//  JSONLAdapterTests.swift
//  OsaurusStatsPackTests
//

import Foundation
import Testing

@testable import OsaurusStatsPack

@Suite("JSONLAdapter")
struct JSONLAdapterTests {
    @Test func streamsObjectLinesInSortedKeyOrder() async throws {
        let url = try TestHelpers.write(#"{"b":2,"a":"one"}"#, filename: "objects.jsonl")
        defer { try? FileManager.default.removeItem(at: url) }

        let adapter = JSONLAdapter()
        _ = try adapter.openDocument(at: url)
        let records = try await TestHelpers.collectRecords(from: adapter)

        #expect(records[0].fields == ["one", "2"])
        #expect(records[0].metadata["jsonKeys"] == "a\tb")
        #expect(records[0].metadata["jsonShape"] == "object")
    }

    @Test func streamsArrayLinesPositionally() async throws {
        let url = try TestHelpers.write(#"["Ada",37,true]"#, filename: "arrays.jsonl")
        defer { try? FileManager.default.removeItem(at: url) }

        let adapter = JSONLAdapter()
        _ = try adapter.openDocument(at: url)
        let records = try await TestHelpers.collectRecords(from: adapter)

        #expect(records[0].fields == ["Ada", "37", "1"])
        #expect(records[0].metadata["jsonShape"] == "array")
    }

    @Test func streamsScalarLinesAndSkipsBlankLines() async throws {
        let url = try TestHelpers.write("\n42\n", filename: "scalars.jsonl")
        defer { try? FileManager.default.removeItem(at: url) }

        let adapter = JSONLAdapter()
        _ = try adapter.openDocument(at: url)
        let records = try await TestHelpers.collectRecords(from: adapter)

        #expect(records.count == 1)
        #expect(records[0].fields == ["42"])
        #expect(records[0].metadata["lineNumber"] == "2")
    }

    @Test func invalidJSONLineThrows() async throws {
        let url = try TestHelpers.write("{nope}", filename: "bad.jsonl")
        defer { try? FileManager.default.removeItem(at: url) }

        let adapter = JSONLAdapter()
        _ = try adapter.openDocument(at: url)

        await #expect(throws: StatsPackError.self) {
            _ = try await TestHelpers.collectRecords(from: adapter)
        }
    }
}
