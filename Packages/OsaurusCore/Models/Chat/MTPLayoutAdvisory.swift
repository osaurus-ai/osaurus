//
//  MTPLayoutAdvisory.swift
//  osaurus
//
//  Detects a Qwen 3.8 Flash-Next (JANG) bundle whose on-disk MTP layout
//  predates the final contract, so the user can re-download a proper copy.
//
//  This ADVISES. It never refuses, never caps, never blocks a load — the
//  model itself still runs from a superseded layout; at worst the MTP
//  speed-up fails to engage or the calibrated draft head is absent. A guess
//  about a bundle's files must not become a wall between a user and their
//  model.
//
//  The final on-disk contract this checks against:
//    - MTP trunk weights live inside the model shards
//      (`model-*.safetensors`), indexed by `model.safetensors.index.json`.
//    - The calibrated draft sidecar lives at
//      `mtp_draft/vmlx_mtp_proposal_head.safetensors` (a SUBFOLDER — its
//      presence is correct and is never flagged).
//    - The bundle ROOT contains no tensor files other than model shards.
//
//  Superseded layouts this recognizes:
//    1. A dedicated MTP shard (`mtp-00001-of-00001.safetensors`) or MTP
//       index (`mtp.safetensors.index.json`) at the root — both withdrawn.
//    2. `model.safetensors.index.json` mapping an `mtp.*` weight to a file
//       that is not in the bundle (a broken index: the load will fail).
//    3. Any stray root-level `*.safetensors` that is not a model shard
//       (e.g. a root-level `vmlx_mtp_proposal_head.safetensors` from an
//       interim layout).
//    4. `vmlx_mtp_proposal_head.json` declaring an eligible draft artifact
//       whose file is missing — the model works, but the runtime silently
//       falls back to an uncalibrated head.
//
//  Cases 1–3 are a broken/legacy layout (MTP may fail to load, or the load
//  may error); case 4 alone means "works, but degraded".
//
//  Scope is deliberately exact: `model_type == "qwen4_exp"` AND a
//  jang_config (embedded in config.json or as jang_config.json) — that is
//  the Qwen 3.8 Flash-Next JANG family and nothing else. The 27B family is
//  `qwen3_5` and must never trigger this, even with identical stray files.
//

import Foundation

/// A non-blocking notice that the SELECTED LOCAL BUNDLE, not the runtime,
/// carries a superseded MTP layout.
public struct MTPLayoutAdvisory: Equatable, Sendable {

    /// How bad the superseded layout is for the user.
    public enum Severity: Equatable, Sendable {
        /// Withdrawn MTP shard/index, broken index entries, or stray root
        /// tensor files: MTP may fail to load, or the load may error.
        case brokenLayout
        /// The bundle declares a calibrated draft head it does not contain:
        /// everything runs, but drafting falls back to an uncalibrated head.
        case missingCalibratedDraft
    }

    /// One detected deviation from the final layout. Stable identifiers —
    /// they key the per-bundle dismissal fingerprint, so renaming a case
    /// would re-show a dismissed advisory.
    public enum Finding: String, Equatable, Sendable, Comparable {
        /// `mtp-00001-of-00001.safetensors` at the bundle root.
        case withdrawnMTPShard = "withdrawn-mtp-shard"
        /// `mtp.safetensors.index.json` at the bundle root.
        case withdrawnMTPIndex = "withdrawn-mtp-index"
        /// `model.safetensors.index.json` maps an `mtp.*` weight to a file
        /// that does not exist in the bundle.
        case brokenIndexEntry = "broken-index-entry"
        /// A root-level `*.safetensors` that is not a model shard.
        case strayRootTensorFile = "stray-root-tensor-file"
        /// `vmlx_mtp_proposal_head.json` names a draft artifact file that
        /// does not exist in the bundle.
        case missingCalibratedDraft = "missing-calibrated-draft"

        public static func < (lhs: Finding, rhs: Finding) -> Bool {
            lhs.rawValue < rhs.rawValue
        }

        var isBrokenLayout: Bool { self != .missingCalibratedDraft }
    }

    public let bundlePath: String
    /// Sorted, deduplicated. Never empty.
    public let findings: [Finding]

    public init(bundlePath: String, findings: [Finding]) {
        self.bundlePath = bundlePath
        self.findings = Array(Set(findings)).sorted()
    }

    public var severity: Severity {
        findings.contains(where: { $0.isBrokenLayout })
            ? .brokenLayout : .missingCalibratedDraft
    }

    /// Keys the "shown once per bundle per improper state" dismissal: the
    /// same bundle in the same improper state stays dismissed, but a state
    /// change (e.g. a partial cleanup that left it differently wrong)
    /// re-arms the notice. Deliberately a plain readable string, not a
    /// runtime hash — `String.hashValue` is seeded per launch and would
    /// forget every dismissal on restart.
    public var fingerprint: String {
        bundlePath + "#" + findings.map(\.rawValue).joined(separator: ",")
    }

    // MARK: - Detection

    /// Inspects a local bundle directory, or nil when the bundle is fine or
    /// out of scope. Cheap file-existence and JSON checks only — no tensor
    /// file is ever opened.
    ///
    /// Nil is the overwhelmingly common answer and must stay cheap: any
    /// bundle that is not a Flash-Next JANG returns after one small
    /// config.json read.
    /// The family gate on its own: a Qwen 3.8 Flash-Next JANG bundle is
    /// `model_type == "qwen4_exp"` AND a jang_config (embedded key or
    /// sidecar file). Shared by the layout advisory and the family-scoped
    /// MTP depth default — one definition of "Flash-Next JANG", not two.
    public static func isFlashNextJANGBundle(
        bundleDirectory: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        let configURL = bundleDirectory.appendingPathComponent("config.json")
        guard let configData = try? Data(contentsOf: configURL),
            let config = (try? JSONSerialization.jsonObject(with: configData))
                as? [String: Any],
            (config["model_type"] as? String) == "qwen4_exp"
        else { return false }
        let jangSidecar = bundleDirectory.appendingPathComponent("jang_config.json")
        return config["jang_config"] != nil
            || fileManager.fileExists(atPath: jangSidecar.path)
    }

    public static func evaluate(
        bundleDirectory: URL,
        fileManager: FileManager = .default
    ) -> MTPLayoutAdvisory? {
        guard isFlashNextJANGBundle(bundleDirectory: bundleDirectory, fileManager: fileManager)
        else { return nil }

        var findings: [Finding] = []

        // Case 1: withdrawn dedicated MTP shard / MTP index at the root.
        let withdrawnShardName = "mtp-00001-of-00001.safetensors"
        if fileManager.fileExists(
            atPath: bundleDirectory.appendingPathComponent(withdrawnShardName).path)
        {
            findings.append(.withdrawnMTPShard)
        }
        if fileManager.fileExists(
            atPath: bundleDirectory
                .appendingPathComponent("mtp.safetensors.index.json").path)
        {
            findings.append(.withdrawnMTPIndex)
        }

        // Case 2: model index maps an mtp.* weight to a file that is gone.
        let indexURL =
            bundleDirectory.appendingPathComponent("model.safetensors.index.json")
        if let indexData = try? Data(contentsOf: indexURL),
            let index = (try? JSONSerialization.jsonObject(with: indexData))
                as? [String: Any],
            let weightMap = index["weight_map"] as? [String: String]
        {
            // One existence probe per distinct file, not per tensor key —
            // an mtp head fans out to hundreds of keys in a handful of files.
            let mtpFiles = Set(
                weightMap.compactMap { key, file in
                    key.hasPrefix("mtp.") ? file : nil
                })
            for file in mtpFiles
            where !fileManager.fileExists(
                atPath: bundleDirectory.appendingPathComponent(file).path)
            {
                findings.append(.brokenIndexEntry)
                break
            }
        }

        // Case 3: stray tensor files at the ROOT. The final contract allows
        // only model shards there; the draft sidecar lives in `mtp_draft/`
        // (a subfolder, untouched by this root-level listing).
        if let entries = try? fileManager.contentsOfDirectory(
            at: bundleDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])
        {
            for entry in entries {
                let name = entry.lastPathComponent
                guard name.hasSuffix(".safetensors") else { continue }
                // Directories can legally end in ".safetensors"; only files
                // are tensor payloads.
                if (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?
                    .isDirectory == true
                {
                    continue
                }
                if isModelShardName(name) { continue }
                // The withdrawn shard already has its own, more specific
                // finding — don't double-report the same file.
                if name == withdrawnShardName { continue }
                findings.append(.strayRootTensorFile)
                break
            }
        }

        // Case 4: the proposal-head stamp promises a calibrated draft
        // artifact the bundle does not contain.
        let stampURL =
            bundleDirectory.appendingPathComponent("vmlx_mtp_proposal_head.json")
        if let stampData = try? Data(contentsOf: stampURL),
            let stamp = (try? JSONSerialization.jsonObject(with: stampData))
                as? [String: Any],
            (stamp["eligible"] as? Bool) == true,
            let artifact = stamp["draft_artifact"] as? [String: Any],
            let file = artifact["file"] as? String,
            !file.isEmpty,
            !fileManager.fileExists(
                atPath: bundleDirectory.appendingPathComponent(file).path)
        {
            findings.append(.missingCalibratedDraft)
        }

        guard !findings.isEmpty else { return nil }
        return MTPLayoutAdvisory(
            bundlePath: bundleDirectory.path, findings: findings)
    }

    /// `model.safetensors` (single-file) or `model-XXXXX-of-YYYYY.safetensors`
    /// (sharded) — the only tensor files the final contract permits at the
    /// bundle root.
    static func isModelShardName(_ name: String) -> Bool {
        if name == "model.safetensors" { return true }
        return name.hasPrefix("model-") && name.hasSuffix(".safetensors")
    }

    // MARK: - Copy

    /// Shown in the banner. Names what was fixed, what this copy is, and the
    /// one action that restores it — without ever implying the model is
    /// unusable.
    public var warningText: String {
        switch severity {
        case .brokenLayout:
            return String(
                localized:
                    "MTP loading for Qwen 3.8 Flash-Next (JANG) was fixed; this copy uses a superseded bundle layout, so the MTP speed-up may fail to load. Re-download to restore MTP.",
                bundle: .module)
        case .missingCalibratedDraft:
            return String(
                localized:
                    "MTP loading for Qwen 3.8 Flash-Next (JANG) was fixed; this copy is missing the calibrated MTP draft head, so drafting quality is reduced. Re-download to restore the calibrated MTP draft head.",
                bundle: .module)
        }
    }

    /// Honest second line: the user may keep using the bundle as-is.
    public var reassuranceText: String {
        switch severity {
        case .brokenLayout:
            return String(
                localized:
                    "You can keep using this copy — worst case the MTP speed-up stays off.",
                bundle: .module)
        case .missingCalibratedDraft:
            return String(
                localized:
                    "You can keep using this copy — responses are unaffected, drafting is just less effective.",
                bundle: .module)
        }
    }

    /// Compact form for a status row where the full sentence will not fit.
    public var shortLabel: String {
        switch severity {
        case .brokenLayout:
            return String(localized: "Superseded bundle layout", bundle: .module)
        case .missingCalibratedDraft:
            return String(localized: "Calibrated MTP draft missing", bundle: .module)
        }
    }
}

/// Per-bundle, per-state "don't nag" memory for the advisory, in the same
/// UserDefaults store the app's other skip-this-notice flags use (e.g. the
/// import guide's "don't show again"). Keyed by the advisory fingerprint so
/// a re-download that lands in a DIFFERENT improper state re-arms the
/// notice, while the dismissed state stays quiet forever.
public enum MTPLayoutAdvisoryDismissals {
    static let defaultsKey = "mtpLayoutAdvisoryDismissedFingerprints"
    /// Old entries are pruned oldest-first past this point; the realistic
    /// population is one or two bundles, so this only guards against a
    /// pathological grow-forever default.
    static let maxStored = 32

    public static func isDismissed(
        _ fingerprint: String, defaults: UserDefaults = .standard
    ) -> Bool {
        (defaults.stringArray(forKey: defaultsKey) ?? []).contains(fingerprint)
    }

    public static func recordDismissal(
        _ fingerprint: String, defaults: UserDefaults = .standard
    ) {
        var stored = defaults.stringArray(forKey: defaultsKey) ?? []
        guard !stored.contains(fingerprint) else { return }
        stored.append(fingerprint)
        if stored.count > maxStored {
            stored.removeFirst(stored.count - maxStored)
        }
        defaults.set(stored, forKey: defaultsKey)
    }
}
