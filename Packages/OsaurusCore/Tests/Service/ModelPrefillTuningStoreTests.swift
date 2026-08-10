//
//  ModelPrefillTuningStoreTests.swift
//  osaurusTests
//
//  Covers the per-model prefill tuning store: round-trip, the mtime-based
//  re-read that lets the CLI (a separate process) update values without a
//  server restart, case-insensitive model matching, and merge-write
//  semantics that preserve other models' records.
//

import Foundation
import Testing

@testable import OsaurusCore

struct ModelPrefillTuningStoreTests {

    private func withTempStore<T>(_ body: (URL) throws -> T) rethrows -> T {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("prefill-tuning-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("prefill-tuning.json")
        return try ModelPrefillTuningStore.$fileURLOverrideForTests.withValue(url) {
            try body(url)
        }
    }

    @Test func missingFileMeansNoOverride() throws {
        try withTempStore { _ in
            #expect(ModelPrefillTuningStore.tunedStepSize(for: "any-model") == nil)
        }
    }

    @Test func roundTripAndCaseInsensitiveLookup() throws {
        try withTempStore { _ in
            try ModelPrefillTuningStore.save(
                record: .init(
                    prefillStepSize: 2_048, chip: "Apple M5 Max",
                    measuredAt: "2026-07-06", benchTTFTMs: 9_420),
                for: "Qwen3.6-35B-A3B-MXFP4-MTP")
            #expect(
                ModelPrefillTuningStore.tunedStepSize(for: "Qwen3.6-35B-A3B-MXFP4-MTP") == 2_048)
            // The chat router lowercases model names; lookup must still hit.
            #expect(
                ModelPrefillTuningStore.tunedStepSize(for: "qwen3.6-35b-a3b-mxfp4-mtp") == 2_048)
        }
    }

    @Test func externalWriteIsPickedUpByMtime() throws {
        try withTempStore { url in
            try ModelPrefillTuningStore.save(
                record: .init(prefillStepSize: 512, chip: nil, measuredAt: nil, benchTTFTMs: nil),
                for: "model-a")
            #expect(ModelPrefillTuningStore.tunedStepSize(for: "model-a") == 512)

            // Simulate the CLI process rewriting the file (fresh JSON, no
            // shared in-process state) with a bumped mtime.
            let json = #"{"model-a": {"prefillStepSize": 4096}}"#
            try Data(json.utf8).write(to: url, options: .atomic)
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(2)], ofItemAtPath: url.path)

            #expect(ModelPrefillTuningStore.tunedStepSize(for: "model-a") == 4_096)
        }
    }

    @Test func mergeWritePreservesOtherModels() throws {
        try withTempStore { _ in
            try ModelPrefillTuningStore.save(
                record: .init(prefillStepSize: 512, chip: nil, measuredAt: nil, benchTTFTMs: nil),
                for: "model-a")
            try ModelPrefillTuningStore.save(
                record: .init(prefillStepSize: 2_048, chip: nil, measuredAt: nil, benchTTFTMs: nil),
                for: "model-b")
            #expect(ModelPrefillTuningStore.tunedStepSize(for: "model-a") == 512)
            #expect(ModelPrefillTuningStore.tunedStepSize(for: "model-b") == 2_048)

            try ModelPrefillTuningStore.removeRecord(for: "model-a")
            #expect(ModelPrefillTuningStore.tunedStepSize(for: "model-a") == nil)
            #expect(ModelPrefillTuningStore.tunedStepSize(for: "model-b") == 2_048)
        }
    }
}
