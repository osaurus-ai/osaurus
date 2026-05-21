//
//  StatsPackRegistrationTests.swift
//  OsaurusStatsPackTests
//

import Testing

import OsaurusCore

@testable import OsaurusStatsPack

@Suite("StatsPack registration")
struct StatsPackRegistrationTests {
    @Test func registerAdapters_addsEveryStatsFormat() throws {
        let registry = FormatAdapterRegistry()
        try StatsPack.registerAdapters(into: registry)

        #expect(
            registry.registeredFormatIdentifiers()
                == ["csv-schema", "jsonl", "sqlite", "tsv"]
        )
    }

    @Test func registerAdapters_rejectsDuplicateStatsFormatClaims() throws {
        let registry = FormatAdapterRegistry()
        try StatsPack.registerAdapters(into: registry)

        do {
            try StatsPack.registerAdapters(into: registry)
            Issue.record("Expected duplicate registration to fail")
        } catch let error as FormatAdapterRegistryError {
            #expect(error == .duplicateRegistration(formatIdentifier: "csv-schema"))
        }
    }
}
