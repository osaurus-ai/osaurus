//
//  ModelSSDResidencyTests.swift
//  OsaurusCoreTests
//
//  The Qwen4Exp n-gram table (Flash-Next affine/JANGH, Allosaurus) stays on SSD; the catalog RAM verdict, the
//  detail sheet and load admission must not count it, while the download size keeps every byte.
//

import Foundation
import Testing

@testable import OsaurusCore

struct ModelSSDResidencyTests {
    /// Bundle with one shard: an n-gram tensor of `ngram` bytes and a weight tensor of `other` bytes.
    private func bundle(modelType: String, ngram: Int, other: Int) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ssd-res-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"model_type":"\#(modelType)"}"#.utf8).write(to: dir.appendingPathComponent("config.json"))
        let header: [String: Any] = [
            "language_model.layers.0.ple.ngram_embedding.shards.0.weight":
                ["dtype": "U32", "shape": [ngram / 4], "data_offsets": [0, ngram]],
            "language_model.layers.0.mlp.gate.weight":
                ["dtype": "U8", "shape": [other], "data_offsets": [ngram, ngram + other]],
        ]
        let bytes = try JSONSerialization.data(withJSONObject: header)
        var length = UInt64(bytes.count).littleEndian
        var file = withUnsafeBytes(of: &length) { Data($0) }
        file.append(bytes)
        file.append(Data(count: ngram + other))
        try file.write(to: dir.appendingPathComponent("model-00001-of-00001.safetensors"))
        return dir
    }

    @Test func localScanCountsOnlyNGramPayloadsForQwen4Exp() throws {
        let dir = try bundle(modelType: "qwen4_exp", ngram: 4000, other: 1000)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(ModelSSDResidency.localNGramBytes(at: dir) == 4000)
        #expect(ModelSSDResidency.localSSDResidentBytes(at: dir) == 4000)
    }

    @Test func otherArchitecturesAreNeverScanned() throws {
        let dir = try bundle(modelType: "qwen3_5", ngram: 4000, other: 1000)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(ModelSSDResidency.localSSDResidentBytes(at: dir) == nil)
    }

    @Test func hubTagsGateTheRemoteLookup() {
        #expect(ModelSSDResidency.mayHaveNGramTable(modelType: nil, tags: ["mlx", "qwen4_exp", "jangh"]))
        #expect(ModelSSDResidency.mayHaveNGramTable(modelType: "qwen4_exp", tags: nil))
        #expect(!ModelSSDResidency.mayHaveNGramTable(modelType: "qwen3_5", tags: ["mlx", "gemma4"]))
    }

    @Test func ramVerdictExcludesTheTableButDownloadSizeKeepsIt() {
        let gb: Int64 = 1 << 30
        // Allosaurus-like: 88 GB download, 53.6 GB of it n-gram -> ~34.4 GB of weights.
        let model = MLXModel(
            id: "OsaurusAI/Allosaurus-v0.1-125B-A6B-JANGH2", name: "Allosaurus", description: "",
            downloadURL: "", downloadSizeBytes: 88 * gb, ssdResidentBytes: 53 * gb + gb / 2)
        #expect(model.totalSizeEstimateBytes == 88 * gb)
        #expect(model.residentWeightEstimateBytes == 34 * gb + gb / 2)
        let assessment = model.memoryAssessment(totalMemoryGB: 128)
        // 34.5 GB x 1.25 runtime inflation = ~43 GB, comfortably inside a 128 GB Mac's budget.
        #expect(assessment.compatibility == .compatible)
        #expect((assessment.estimatedRunningMemoryGB ?? 0) < 45)

        let whole = MLXModel(id: "x", name: "x", description: "", downloadURL: "", downloadSizeBytes: 88 * gb)
        #expect(whole.memoryAssessment(totalMemoryGB: 128).compatibility != .compatible)
    }

    @Test func copiesCarryTheSSDResidentBytes() {
        let model = MLXModel(id: "a/b", name: "b", description: "", downloadURL: "", ssdResidentBytes: 7)
        #expect(model.withDownloadSize(100).ssdResidentBytes == 7)
        #expect(model.withDownloads(3).ssdResidentBytes == 7)
        #expect(model.withSSDResidentBytes(9).ssdResidentBytes == 9)
        #expect(model.withSSDResidentBytes(nil).ssdResidentBytes == 7)
    }

    @Test func loadAdmissionUsesTheSameRule() throws {
        let dir = try bundle(modelType: "qwen4_exp", ngram: 4000, other: 1000)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(ModelRuntime.residentWeightBytes(rawWeightsBytes: 5000 + 200, modelDirectory: dir) == 1200)
        let plain = try bundle(modelType: "qwen3_5", ngram: 4000, other: 1000)
        defer { try? FileManager.default.removeItem(at: plain) }
        #expect(ModelRuntime.residentWeightBytes(rawWeightsBytes: 5200, modelDirectory: plain) == 5200)
    }

    @Test func craftedHeadersCannotTrapOrInflateTheTable() throws {
        let hostile: [String: Any] = [
            "a.ple.ngram_embedding.x": ["data_offsets": [Int.min, Int.max]],
            "b.ple.ngram_embedding.x": ["data_offsets": [-5, 10]],
            "c.ple.ngram_embedding.x": ["data_offsets": [10, 5]],
            "d.ple.ngram_embedding.x": ["data_offsets": [0, Int.max]],
            "e.ple.ngram_embedding.x": ["data_offsets": [0, 100]],
        ]
        let header = try JSONSerialization.data(withJSONObject: hostile)
        // No trap; with a known payload length, ranges past the file are ignored.
        #expect(ModelSSDResidency.ngramBytes(inHeader: header, payloadLength: 100) == 100)
        _ = ModelSSDResidency.ngramBytes(inHeader: header)
    }
}
