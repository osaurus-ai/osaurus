//
//  FormatAdapterRegistryTests.swift
//  osaurusTests
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("FormatAdapterRegistry")
struct FormatAdapterRegistryTests {
    @Test func register_addsFactoryByFormatIdentifier() throws {
        let registry = FormatAdapterRegistry()
        try registry.register(MagicFormatAdapter.self) { MagicFormatAdapter() }

        #expect(registry.registeredFormatIdentifiers() == ["magic"])
        #expect(try registry.makeAdapter(formatIdentifier: "MAGIC") is MagicFormatAdapter)
    }

    @Test func register_rejectsDuplicateFormatIdentifier() throws {
        let registry = FormatAdapterRegistry()
        try registry.register(MagicFormatAdapter.self) { MagicFormatAdapter() }

        do {
            try registry.register(MagicFormatAdapter.self) { MagicFormatAdapter() }
            Issue.record("Expected duplicate format registration to throw")
        } catch let error as FormatAdapterRegistryError {
            #expect(error == .duplicateRegistration(formatIdentifier: "magic"))
        }
    }

    @Test func adapter_detectsByBytePattern() throws {
        let registry = FormatAdapterRegistry()
        try registry.register(MagicFormatAdapter.self) { MagicFormatAdapter() }

        #expect(registry.adapter(detecting: Data([0xCA, 0xFE, 0x01])) is MagicFormatAdapter)
        #expect(registry.adapter(detecting: Data([0xBA, 0xAD, 0xF0, 0x0D])) == nil)
    }

    @Test func adapter_detectsURLByBoundedBytePatternRead() throws {
        let registry = FormatAdapterRegistry()
        try registry.register(MagicFormatAdapter.self) { MagicFormatAdapter() }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-magic.bin")
        try Data([0xCA, 0xFE, 0x99, 0x00]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(try registry.adapter(detecting: url) is MagicFormatAdapter)
    }

    private final class MagicFormatAdapter: FormatAdapter, @unchecked Sendable {
        static let formatIdentifier = "magic"
        static let detectionBytePatterns = [Data([0xCA, 0xFE])]

        func openDocument(at url: URL) throws -> DocumentReference {
            DocumentReference(
                formatIdentifier: Self.formatIdentifier,
                displayName: url.lastPathComponent,
                fileSize: 0
            )
        }

        func streamRecords(into continuation: AsyncStream<Record>.Continuation) async throws {
            continuation.finish()
        }
    }
}
