//
//  ModelCapabilityLedger.swift
//  osaurus
//
//  Measured model-capability records that feature gates consult before
//  falling back to the hardcoded name lists scattered through the runtime.
//
//  Why: every "does model X support Y at speed Z" policy in osaurus is
//  currently a name-substring list maintained by hand (hybrid families,
//  production blocklists, per-family decode profiles). Names lie — renames
//  and finetunes slip past them — and static claims lie too (a bundle's MTP
//  tuning stamp promises 1.56× that the serving path doesn't deliver; the
//  optimal prefill step turned out to be per-model, not per-chip). The
//  ledger is where *measured* facts live: seeded from today's hardcoded
//  knowledge so day-one behavior is identical, overridable by measurement
//  (the `osaurus bench` gauntlet writes records), never by marketing name.
//
//  This file is the skeleton: the record schema, the mtime-cached store
//  (same pattern as `ModelPrefillTuningStore`), the seed rules, and the
//  first consumer (the production-serving block in
//  `MLXService.validateRuntimePolicy`). Gauntlet probes add fields and
//  writers in follow-ups.
//
//  File: ~/.osaurus/config/model-ledger.json — written by the CLI (a
//  separate process), so reads are mtime-checked. Keys are normalized model
//  names (lowercased, `-` → `_`); records carry the weights digest for
//  invalidation once the gauntlet computes it.
//

import Foundation
import os.log

private let ledgerLog = Logger(subsystem: "com.dinoki.osaurus", category: "CapabilityLedger")

enum ModelCapabilityLedger {

    enum Verdict: String, Codable, Sendable {
        case pass
        case fail
        case untested
    }

    struct Record: Codable, Sendable, Equatable {
        /// Gate for serving the model at all. `.fail` blocks with `blockReason`;
        /// `.pass` explicitly clears a seed-rule block (measured beats static);
        /// `.untested`/absent falls through to the seed rules.
        var productionServing: Verdict?
        var blockReason: String?

        /// Provenance. `source` is "seed" | "gauntlet" | "central"; `digest`
        /// (sha256 of the weights) arrives with gauntlet-written records and
        /// is what makes a record survive renames and die on re-quantization.
        var source: String?
        var digest: String?
        var chip: String?
        var measuredAt: String?
    }

    // MARK: - Seed rules (compiled-in; reproduce today's hardcoded behavior)

    /// A seed rule is a name-substring predicate exactly because the
    /// hardcoded knowledge it replaces was name-substring based. Measured
    /// records are exact-key + digest; only seeds pattern-match.
    private struct SeedRule {
        let nameContains: String
        let record: Record
    }

    private static let seedRules: [SeedRule] = [
        // Migrated verbatim from `MLXService.isBlockedProductionModel`.
        SeedRule(
            nameContains: "zaya1_vl_8b_jangtq_k",
            record: Record(
                productionServing: .fail,
                blockReason:
                    "ZAYA1-VL JANGTQ_K is a diagnostic artifact with a proven first-token fidelity failure; use zaya1-vl-8b-mxfp4 or zaya1-vl-8b-jangtq4 for production serving.",
                source: "seed"
            )
        )
    ]

    // MARK: - Lookup

    /// Returns the block reason when `modelName`/`modelId` must not serve
    /// production traffic, or nil when serving is allowed. Resolution order:
    /// measured file record (exact normalized key) first — a measured `.pass`
    /// explicitly clears a seed block — then compiled-in seed rules.
    static func productionServingBlockReason(modelName: String, modelId: String) -> String? {
        let keys = [normalize(modelName), normalize(modelId)]

        let records = currentRecords()
        for key in keys {
            guard let record = records[key], let verdict = record.productionServing else {
                continue
            }
            switch verdict {
            case .fail:
                return record.blockReason
                    ?? "Model is marked unfit for production serving in the capability ledger."
            case .pass:
                return nil
            case .untested:
                break
            }
        }

        let combined = keys.joined(separator: " ")
        for rule in seedRules where combined.contains(rule.nameContains) {
            return rule.record.blockReason
        }
        return nil
    }

    /// Names arrive in picker form ("ZAYA1-VL-8B-JANGTQ_K"), router form
    /// (lowercased), and repo form ("Org/Name"); normalize the same way the
    /// hardcoded list did so seeds reproduce its decisions bit-for-bit.
    static func normalize(_ name: String) -> String {
        name.lowercased().replacingOccurrences(of: "-", with: "_")
    }

    // MARK: - Store (mtime-cached read; merge write)

    /// Test-only injection point, task-scoped so parallel tests don't race.
    @TaskLocal
    static var fileURLOverrideForTests: URL?

    static var fileURL: URL {
        fileURLOverrideForTests
            ?? OsaurusPaths.config().appendingPathComponent("model-ledger.json")
    }

    private struct CacheBox: @unchecked Sendable {
        var records: [String: Record] = [:]
        var mtime: Date?
        var checkedURL: URL?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache = CacheBox()

    static func currentRecords() -> [String: Record] {
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
        if mtime != nil,
            let data = try? Data(contentsOf: url),
            let decoded = try? JSONDecoder().decode([String: Record].self, from: data) {
            records = decoded
            ledgerLog.info(
                "loaded \(records.count, privacy: .public) capability record(s)")
        }
        cache = CacheBox(records: records, mtime: mtime, checkedURL: url)
        return records
    }

    /// Merge-writes one record under the normalized key. Reads the file
    /// fresh (not the cache) so two writers interleaving lose at most their
    /// own key, never the whole file.
    static func save(record: Record, for modelName: String) throws {
        let url = fileURL
        var records: [String: Record] = [:]
        if let data = try? Data(contentsOf: url),
            let decoded = try? JSONDecoder().decode([String: Record].self, from: data) {
            records = decoded
        }
        records[normalize(modelName)] = record
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(records).write(to: url, options: .atomic)
    }
}
