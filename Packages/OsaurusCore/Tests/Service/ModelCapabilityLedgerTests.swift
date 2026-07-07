//
//  ModelCapabilityLedgerTests.swift
//  osaurusTests
//
//  Covers the capability-ledger skeleton's contracts: seed rules reproduce
//  the old hardcoded production-block decisions bit-for-bit, measured file
//  records override seeds in both directions, and external writes are
//  picked up without a restart (mtime re-read).
//

import Foundation
import Testing

@testable import OsaurusCore

struct ModelCapabilityLedgerTests {

    private func withTempLedger<T>(_ body: (URL) throws -> T) rethrows -> T {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ledger-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("model-ledger.json")
        return try ModelCapabilityLedger.$fileURLOverrideForTests.withValue(url) {
            try body(url)
        }
    }

    // MARK: - Seed rules reproduce the retired hardcoded check

    @Test func seedBlocksZayaDiagnosticArtifactInEveryNameForm() throws {
        try withTempLedger { _ in
            // Picker casing, router lowercase, dash and underscore forms,
            // and org-prefixed repo ids — all forms the old
            // `isBlockedProductionModel` substring check caught.
            for (name, id) in [
                ("ZAYA1-VL-8B-JANGTQ_K", "Zyphra/ZAYA1-VL-8B-JANGTQ_K"),
                ("zaya1-vl-8b-jangtq_k", "zyphra/zaya1-vl-8b-jangtq_k"),
                ("zaya1_vl_8b_jangtq_k", "zaya1_vl_8b_jangtq_k"),
                ("Some Alias", "Org/ZAYA1-VL-8B-JANGTQ_K"),
            ] {
                let reason = ModelCapabilityLedger.productionServingBlockReason(
                    modelName: name, modelId: id)
                #expect(reason?.contains("diagnostic artifact") == true, "expected block for \(name)")
            }
        }
    }

    @Test func seedDoesNotBlockTheRecommendedReplacements() throws {
        try withTempLedger { _ in
            for (name, id) in [
                ("zaya1-vl-8b-mxfp4", "Zyphra/ZAYA1-VL-8B-mxfp4"),
                ("zaya1-vl-8b-jangtq4", "Zyphra/ZAYA1-VL-8B-JANGTQ4"),
                ("gemma-4-e2b-it-4bit", "OsaurusAI/gemma-4-E2B-it-4bit"),
            ] {
                #expect(
                    ModelCapabilityLedger.productionServingBlockReason(
                        modelName: name, modelId: id) == nil,
                    "expected no block for \(name)")
            }
        }
    }

    // MARK: - Measured records beat seeds (both directions)

    @Test func measuredPassClearsASeedBlock() throws {
        try withTempLedger { _ in
            try ModelCapabilityLedger.save(
                record: .init(
                    productionServing: .pass, blockReason: nil,
                    source: "gauntlet", digest: "sha256:abc", chip: "Apple M5 Max",
                    measuredAt: "2026-07-07"),
                for: "ZAYA1-VL-8B-JANGTQ_K")
            #expect(
                ModelCapabilityLedger.productionServingBlockReason(
                    modelName: "ZAYA1-VL-8B-JANGTQ_K", modelId: "Zyphra/ZAYA1-VL-8B-JANGTQ_K")
                    == nil)
        }
    }

    @Test func measuredFailBlocksAModelNoSeedKnows() throws {
        try withTempLedger { _ in
            try ModelCapabilityLedger.save(
                record: .init(
                    productionServing: .fail,
                    blockReason: "Gauntlet: template probe leaked special tokens.",
                    source: "gauntlet", digest: nil, chip: nil, measuredAt: nil),
                for: "some-broken-finetune")
            let reason = ModelCapabilityLedger.productionServingBlockReason(
                modelName: "Some-Broken-Finetune", modelId: "org/some-broken-finetune")
            #expect(reason == "Gauntlet: template probe leaked special tokens.")
        }
    }

    @Test func untestedRecordFallsThroughToSeeds() throws {
        try withTempLedger { _ in
            try ModelCapabilityLedger.save(
                record: .init(
                    productionServing: .untested, blockReason: nil,
                    source: "gauntlet", digest: nil, chip: nil, measuredAt: nil),
                for: "zaya1-vl-8b-jangtq_k")
            #expect(
                ModelCapabilityLedger.productionServingBlockReason(
                    modelName: "zaya1-vl-8b-jangtq_k", modelId: "zaya1-vl-8b-jangtq_k") != nil)
        }
    }

    // MARK: - External writes picked up without restart

    @Test func externalWriteIsPickedUpByMtime() throws {
        try withTempLedger { url in
            #expect(
                ModelCapabilityLedger.productionServingBlockReason(
                    modelName: "model-x", modelId: "model-x") == nil)

            let json = #"{"model_x": {"productionServing": "fail", "blockReason": "external"}}"#
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(json.utf8).write(to: url, options: .atomic)
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(2)], ofItemAtPath: url.path)

            #expect(
                ModelCapabilityLedger.productionServingBlockReason(
                    modelName: "model-x", modelId: "model-x") == "external")
        }
    }
}
