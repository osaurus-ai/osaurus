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

import CryptoKit
import Foundation
import os.log

private let ledgerLog = Logger(subsystem: "com.dinoki.osaurus", category: "CapabilityLedger")

enum ModelCapabilityLedger {
    @TaskLocal static var failVerificationWriteForTests = false

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

        /// Digest-bound verification projection. The full evidence remains in
        /// the registered JSON artifact; the ledger only points at it and never
        /// promotes a model by name or load success.
        var verificationClassification: String?
        var verificationModelId: String?
        var verificationDigest: String?
        var verificationMeasuredAt: String?
        var verificationArtifactPath: String?

        init(
            productionServing: Verdict? = nil,
            blockReason: String? = nil,
            source: String? = nil,
            digest: String? = nil,
            chip: String? = nil,
            measuredAt: String? = nil,
            verificationClassification: String? = nil,
            verificationModelId: String? = nil,
            verificationDigest: String? = nil,
            verificationMeasuredAt: String? = nil,
            verificationArtifactPath: String? = nil
        ) {
            self.productionServing = productionServing
            self.blockReason = blockReason
            self.source = source
            self.digest = digest
            self.chip = chip
            self.measuredAt = measuredAt
            self.verificationClassification = verificationClassification
            self.verificationModelId = verificationModelId
            self.verificationDigest = verificationDigest
            self.verificationMeasuredAt = verificationMeasuredAt
            self.verificationArtifactPath = verificationArtifactPath
        }
    }

    // MARK: - Seed rules (compiled-in; reproduce today's hardcoded behavior)

    /// A seed rule is a name-substring predicate exactly because the
    /// hardcoded knowledge it replaces was name-substring based. Measured
    /// records are exact-key + digest; only seeds pattern-match.
    private struct SeedRule {
        let nameContains: String
        let record: Record
    }

    /// Currently empty: the ZAYA1-VL JANGTQ_K block that seeded this list
    /// was lifted upstream (#1907 unblocked the bundle after a vmlx repin
    /// fixed its first-token fidelity failure), so main ships with no
    /// hardcoded production blocks. The mechanism stays as the extension
    /// point for future compiled-in knowledge; measured ledger records are
    /// the primary path.
    private static let seedRules: [SeedRule] = []

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
        if mtime != nil {
            do {
                let data = try Data(contentsOf: url)
                records = try JSONDecoder().decode([String: Record].self, from: data)
                ledgerLog.info(
                    "loaded \(records.count, privacy: .public) capability record(s)")
            } catch {
                ledgerLog.error("capability ledger is unreadable or corrupt; preserving prior cache")
                return cache.checkedURL == url ? cache.records : [:]
            }
        }
        cache = CacheBox(records: records, mtime: mtime, checkedURL: url)
        return records
    }

    /// Merge-writes one record under the normalized key. Reads the file
    /// fresh (not the cache) and merges at the raw JSON level — only the
    /// target key is overlaid, so every other record survives verbatim,
    /// including fields this build does not know about (the gauntlet-written
    /// `probes`/`evidence` maps; a `[String: Record]` decode/re-encode round
    /// trip would strip them from every record). All writers share the same
    /// lock, so each merge observes the prior completed write.
    static func save(record: Record, for modelName: String) throws {
        lock.lock()
        defer { lock.unlock() }
        let url = fileURL
        var records = try rawRecordsForWrite(at: url)
        let encoded = try JSONEncoder().encode(record)
        records[normalize(modelName)] = try JSONSerialization.jsonObject(with: encoded)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(
            withJSONObject: records, options: [.prettyPrinted, .sortedKeys])
        try writePrivateLedger(data, to: url)
    }

    static func saveVerification(
        classification: LocalModelVerificationClassification,
        digest: String,
        artifactPath: String,
        measuredAt: String,
        for modelName: String
    ) throws {
        if failVerificationWriteForTests {
            throw CocoaError(.fileWriteUnknown)
        }
        guard LocalModelVerificationAuthority.validDigest(digest) else {
            throw CocoaError(.fileWriteInvalidFileName, userInfo: [
                NSLocalizedDescriptionKey: "Verification evidence requires a full SHA-256 bundle digest."
            ])
        }
        lock.lock()
        defer { lock.unlock() }
        let url = fileURL
        var records = try rawRecordsForWrite(at: url)
        let key = verificationStorageKey(modelName)
        var target = records[key] as? [String: Any] ?? [:]
        target["verificationClassification"] = classification.rawValue
        target["verificationModelId"] = modelName
        target["verificationDigest"] = digest
        target["verificationMeasuredAt"] = measuredAt
        target["verificationArtifactPath"] = artifactPath
        records[key] = target
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(
            withJSONObject: records, options: [.prettyPrinted, .sortedKeys])
        try writePrivateLedger(data, to: url)
    }

    static func removeVerification(for modelName: String) throws {
        lock.lock()
        defer { lock.unlock() }
        let url = fileURL
        var records = try rawRecordsForWrite(at: url)
        records.removeValue(forKey: verificationStorageKey(modelName))
        let data = try JSONSerialization.data(
            withJSONObject: records, options: [.prettyPrinted, .sortedKeys])
        try writePrivateLedger(data, to: url)
    }

    static func verificationStorageKey(_ modelId: String) -> String {
        let digest = SHA256.hash(data: Data(modelId.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "verification:\(digest)"
    }

    private static func writePrivateLedger(_ data: Data, to url: URL) throws {
        let fileManager = FileManager.default
        let temporaryURL = url.deletingLastPathComponent().appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).tmp"
        )
        defer { try? fileManager.removeItem(at: temporaryURL) }
        guard fileManager.createFile(
            atPath: temporaryURL.path,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        if fileManager.fileExists(atPath: url.path) {
            let values = try url.resourceValues(forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey,
            ])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw CocoaError(.fileWriteInvalidFileName)
            }
            _ = try fileManager.replaceItemAt(url, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: url)
        }
    }

    private static func rawRecordsForWrite(at url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        guard let records = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return records
    }
}
