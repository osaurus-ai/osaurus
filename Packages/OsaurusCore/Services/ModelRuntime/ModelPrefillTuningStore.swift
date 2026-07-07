//
//  ModelPrefillTuningStore.swift
//  osaurus
//
//  Per-model prefill step-size overrides, measured rather than assumed.
//
//  The optimal chunked-prefill step is model-architecture-dependent, not
//  hardware-tier-dependent: on the same M5 Max, gemma-4-E2B prefills fastest
//  at vmlx's default 512 (2048 costs +25–50% TTFT at 8K–32K), while
//  Qwen3.6-35B MoE is 22–24% faster at 2048. A global setting or a
//  chip-tier table is therefore wrong for someone; the only correct value
//  is one measured for the (model, machine) pair. `osaurus bench
//  --tune-prefill` runs that measurement and persists the winner here;
//  the runtime applies it per model.
//
//  File: ~/.osaurus/config/prefill-tuning.json — written by the CLI (a
//  separate process), so reads are mtime-checked instead of cached forever.
//  The read cost is one stat(2) per generation, invisible next to a prefill.
//

import Foundation
import os.log

private let tuningLog = Logger(subsystem: "com.dinoki.osaurus", category: "PrefillTuning")

enum ModelPrefillTuningStore {
    struct Record: Codable, Sendable, Equatable {
        let prefillStepSize: Int
        /// Provenance, for humans reading the file and for invalidation
        /// decisions: a record measured on another machine (Migration
        /// Assistant) or an old bundle revision is visibly stale.
        let chip: String?
        let measuredAt: String?
        let benchTTFTMs: Double?
    }

    /// Test-only injection point, scoped per task tree (same pattern as
    /// `ModelRuntime.sidecarFetcherForTests`) so parallel tests don't race.
    @TaskLocal
    static var fileURLOverrideForTests: URL?

    static var fileURL: URL {
        fileURLOverrideForTests
            ?? OsaurusPaths.config().appendingPathComponent("prefill-tuning.json")
    }

    // MARK: - Runtime read (nonisolated, mtime-cached)

    private struct CacheBox: @unchecked Sendable {
        var records: [String: Record] = [:]
        var mtime: Date?
        var checkedURL: URL?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache = CacheBox()

    /// Tuned step size for `modelName`, or nil when no measurement exists.
    /// Keys are matched case-insensitively because the chat router
    /// lowercases model names while the picker preserves bundle casing.
    static func tunedStepSize(for modelName: String) -> Int? {
        let records = currentRecords()
        if let record = records[modelName] { return record.prefillStepSize }
        let lowered = modelName.lowercased()
        return records.first { $0.key.lowercased() == lowered }?.value.prefillStepSize
    }

    private static func currentRecords() -> [String: Record] {
        let url = fileURL
        let mtime =
            (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate])
            as? Date

        lock.lock()
        defer { lock.unlock() }
        if cache.checkedURL == url, cache.mtime == mtime {
            return cache.records
        }
        var records: [String: Record] = [:]
        if let mtime,
            let data = try? Data(contentsOf: url),
            let decoded = try? JSONDecoder().decode([String: Record].self, from: data) {
            records = decoded
            tuningLog.info(
                "loaded \(records.count, privacy: .public) prefill tuning record(s) (mtime \(mtime.ISO8601Format(), privacy: .public))"
            )
        }
        cache = CacheBox(records: records, mtime: mtime, checkedURL: url)
        return records
    }

    // MARK: - Write (used by the CLI tune verb and tests)

    /// Merge-writes one record. Reads the file fresh (not the cache) so two
    /// writers interleaving lose at most their own key, never the whole file.
    static func save(record: Record, for modelName: String) throws {
        let url = fileURL
        var records: [String: Record] = [:]
        if let data = try? Data(contentsOf: url),
            let decoded = try? JSONDecoder().decode([String: Record].self, from: data) {
            records = decoded
        }
        records[modelName] = record
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(records).write(to: url, options: .atomic)
    }

    static func removeRecord(for modelName: String) throws {
        let url = fileURL
        guard let data = try? Data(contentsOf: url),
            var records = try? JSONDecoder().decode([String: Record].self, from: data)
        else { return }
        records.removeValue(forKey: modelName)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(records).write(to: url, options: .atomic)
    }
}
