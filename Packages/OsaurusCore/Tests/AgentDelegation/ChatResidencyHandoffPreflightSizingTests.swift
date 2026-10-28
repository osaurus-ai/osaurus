//
//  ChatResidencyHandoffPreflightSizingTests.swift
//  osaurusTests
//
//  The delegation RAM preflight sizes a spawn model by the weights it keeps
//  resident, not by its download.
//

import Foundation
import Testing

@testable import OsaurusCore

struct ChatResidencyHandoffPreflightSizingTests {
    /// Allosaurus v0.1: a 94.57 GB download of which 57.6 GB are n-gram tables
    /// read from SSD (measured resident weights: 36.97 GB).
    private static let download: Int64 = 94_572_043_640
    private static let ssdTables: Int64 = 57_600_276_480
    private static let allosaurus = MLXModel(
        id: "OsaurusAI/Allosaurus-v0.1-125B-A6B-JANGH2",
        name: "Allosaurus-v0.1-125B-A6B-JANGH2",
        description: "",
        downloadURL: "",
        downloadSizeBytes: download,
        ssdResidentBytes: ssdTables
    )

    @Test func spawnModelIsSizedByResidentWeights() {
        #expect(ChatResidencyHandoff.requiredResidentBytes(for: Self.allosaurus) == Self.download - Self.ssdTables)
    }

    @Test func residentSizingFitsAllosaurusOnA96GBMac() {
        // The preflight needs 1.3 × required + headroom. By download that is
        // ~126 GB, more than a 96 GB Mac has; by resident weights it is ~51 GB.
        let physical = Double(96 * 1024 * 1024 * 1024)
        func needed(_ bytes: Int64) -> Double {
            Double(bytes) * 1.3 + Double(ChatResidencyHandoff.headroomBytes)
        }
        #expect(needed(Self.download) > physical)
        #expect(needed(ChatResidencyHandoff.requiredResidentBytes(for: Self.allosaurus)) < physical)
    }

    @Test func modelsWithoutSSDTablesAreSizedByTheirDownload() {
        let plain = MLXModel(
            id: "OsaurusAI/Plain-Model",
            name: "Plain-Model",
            description: "",
            downloadURL: "",
            downloadSizeBytes: 12_000_000_000
        )
        #expect(ChatResidencyHandoff.requiredResidentBytes(for: plain) == 12_000_000_000)
    }
}
