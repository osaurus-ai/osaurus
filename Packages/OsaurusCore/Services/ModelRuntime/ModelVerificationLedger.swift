//
//  ModelVerificationLedger.swift
//  osaurus
//
//  Autorun-side writer for the model capability ledger at
//  `~/.osaurus/config/model-ledger.json`.
//
//  CROSS-REFERENCE: this is a deliberate LOCAL MIRROR of the ledger JSON
//  contract owned by `ModelCapabilityLedger` (mlx-perf ledger PR, unmerged)
//  and read by the gauntlet CLI (#1916, also on an unmerged branch). This
//  file must stay self-contained on `main`; when the ledger PR lands, fold
//  this writer into `ModelCapabilityLedger` and delete the mirror. The two
//  sides meet ONLY at the file contract:
//
//  {
//    "version": 1,
//    "models": {
//      "<normalized key>": {              // lowercased, non [a-z0-9.] -> "_"
//        "displayName": "<name as installed>",
//        "chip": "Apple M3 Pro",          // machine the probes ran on
//        "updatedAt": "ISO-8601",
//        "probes": {
//          "load":         { "verdict": "pass|fail|skipped",
//                            "evidence": "...", "source": "autorun",
//                            "at": "ISO-8601" },
//          "templateLeak": { ... same shape ... }
//        }
//        // "productionServing" is NEVER written here — see below.
//      }
//    }
//  }
//
//  Merge semantics: every write re-reads the file and only replaces the
//  fields this writer owns (`probes.load`, `probes.templateLeak`,
//  `displayName`, `chip`, `updatedAt`). Foreign records, foreign probe
//  entries (e.g. the gauntlet's HTTP probes), and unknown fields on our own
//  record are preserved byte-for-value, so the autorun and the explicit
//  gauntlet can interleave writes without clobbering each other.
//
//  `productionServing` is intentionally never written by autorun v1: a
//  BACKGROUND probe must never be able to block (or bless) a model for
//  serving. Only the explicit, user-invoked gauntlet — which runs the full
//  HTTP probe set — may set or clear that field. Autorun only contributes
//  raw probe evidence for the gauntlet and future gates to read.
//

import Darwin
import Foundation

enum ModelVerificationLedger {
    /// Ledger file: `~/.osaurus/config/model-ledger.json`.
    static func defaultFileURL() -> URL {
        OsaurusPaths.config().appendingPathComponent("model-ledger.json")
    }

    /// Normalized record key shared with the gauntlet CLI: lowercased, every
    /// character outside `[a-z0-9.]` becomes `_`, runs collapsed, edges
    /// trimmed. `"Qwen3-4B Instruct"` -> `"qwen3_4b_instruct"`.
    static func normalizedKey(for modelName: String) -> String {
        var out = ""
        out.reserveCapacity(modelName.count)
        var lastWasUnderscore = false
        for scalar in modelName.lowercased().unicodeScalars {
            let isAllowed = (scalar >= "a" && scalar <= "z") || (scalar >= "0" && scalar <= "9") || scalar == "."
            if isAllowed {
                out.unicodeScalars.append(scalar)
                lastWasUnderscore = false
            } else if !lastWasUnderscore {
                out.append("_")
                lastWasUnderscore = true
            }
        }
        while out.hasPrefix("_") { out.removeFirst() }
        while out.hasSuffix("_") { out.removeLast() }
        return out
    }

    /// Merge one autorun probe outcome into the ledger, preserving every
    /// field this writer doesn't own. Uses `JSONSerialization` (not Codable)
    /// on purpose: unknown top-level fields, foreign model records, foreign
    /// probe entries, and `productionServing` must round-trip untouched.
    ///
    /// Single-writer by construction in-app (`ModelVerificationScheduler`
    /// serializes runs); the atomic write keeps a concurrent CLI reader from
    /// ever seeing a torn file.
    static func recordAutorunProbes(
        modelName: String,
        outcome: VerificationProbeOutcome,
        chip: String?,
        at now: Date = Date(),
        fileURL: URL? = nil
    ) throws {
        let url = fileURL ?? defaultFileURL()
        let timestamp = ISO8601DateFormatter().string(from: now)

        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: url) {
            root = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
        }
        if root["version"] == nil { root["version"] = 1 }

        var models = root["models"] as? [String: Any] ?? [:]
        let key = normalizedKey(for: modelName)
        var record = models[key] as? [String: Any] ?? [:]
        var probes = record["probes"] as? [String: Any] ?? [:]

        func probeEntry(verdict: VerificationProbeVerdict, evidence: String) -> [String: Any] {
            [
                "verdict": verdict.rawValue,
                "evidence": evidence,
                "source": "autorun",
                "at": timestamp,
            ]
        }

        probes["load"] = probeEntry(
            verdict: outcome.loadVerdict,
            evidence: outcome.loadEvidence
        )
        probes["templateLeak"] = probeEntry(
            verdict: outcome.templateLeakVerdict,
            evidence: outcome.templateLeakEvidence
        )
        record["probes"] = probes
        record["displayName"] = modelName
        if let chip { record["chip"] = chip }
        record["updatedAt"] = timestamp
        // NOTE: record["productionServing"] is deliberately left exactly as
        // found (present or absent) — see the header for why autorun must
        // never touch the serving gate.

        models[key] = record
        root["models"] = models

        OsaurusPaths.ensureExistsSilent(url.deletingLastPathComponent())
        let data = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: url, options: [.atomic])
    }

    /// Chip identifier for the ledger's `chip` field.
    ///
    /// CROSS-REFERENCE: `ChipProfile` (mlx-perf branch, unmerged) is the
    /// canonical chip descriptor; it is not on `main`, so autorun reads
    /// `machdep.cpu.brand_string` directly. Replace with
    /// `ChipProfile.current` when that PR lands.
    static func currentChipBrandString() -> String? {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else {
            return nil
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0) == 0 else {
            return nil
        }
        let value = String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
