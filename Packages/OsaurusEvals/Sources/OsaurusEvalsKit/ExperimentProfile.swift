//
//  ExperimentProfile.swift
//  OsaurusEvalsKit
//
//  Typed, validated, eval-scoped profile for the context-optimization
//  harness: the JSON artifact an operator (or the optimizer command)
//  hands the CLI to say "compose THIS variant". Every axis is optional
//  — an empty profile is byte-for-byte production composition — and the
//  quality-critical contracts (capabilities_discover/load gateway,
//  constrained agent-loop schema, grounding, platform/persona) are
//  refused at decode+validate time, mirroring the second lock inside
//  `PromptComposerExperiment` itself.
//
//  Profiles are recorded into `RunEnvironment` (name + hash + resolved
//  feature vector) so any report produced under a profile is exactly
//  reproducible and never silently comparable with a baseline run.
//

import Foundation
import OsaurusCore

public struct ExperimentProfile: Sendable, Codable, Equatable {
    /// Stable identifier, e.g. "drop-code-style" or "hotset-minimal".
    /// Lands in `RunEnvironment.experimentProfile` and artifact names.
    public let name: String
    /// Human-readable intent — WHY this variant exists.
    public let description: String?
    /// Force compact/full prompt selection regardless of the model's
    /// resolved preference. nil keeps the production resolver.
    public let forceCompactPrompt: Bool?
    /// Prompt section ids to drop after gated composition. Protected
    /// ids (`PromptComposerExperiment.protectedSectionIds`) are refused.
    public let dropSections: [String]?
    /// Tool names to strip from the request schema (they stay registered
    /// and reachable via `capabilities_load` — the defer-to-discovery
    /// architecture). Protected names are refused.
    public let deferTools: [String]?
    /// Compact the results `capabilities_load` writes into history
    /// (smaller skill-reference budget, skeleton schemas). Saves
    /// cumulative/history tokens, not first-step surface — only model
    /// runs can price it. nil/false keeps production behavior.
    public let compactLoadedResults: Bool?

    public init(
        name: String,
        description: String? = nil,
        forceCompactPrompt: Bool? = nil,
        dropSections: [String]? = nil,
        deferTools: [String]? = nil,
        compactLoadedResults: Bool? = nil
    ) {
        self.name = name
        self.description = description
        self.forceCompactPrompt = forceCompactPrompt
        self.dropSections = dropSections
        self.deferTools = deferTools
        self.compactLoadedResults = compactLoadedResults
    }

    /// The production baseline: no overrides at all. Running under this
    /// profile is IDENTICAL to running with no profile — it exists so
    /// paired A/B artifacts can both carry an explicit profile record.
    public static let baseline = ExperimentProfile(
        name: "baseline",
        description: "Production composition — no overrides."
    )

    // MARK: - Validation

    /// All problems that make this profile unusable, empty when valid.
    /// Delegates the contract guards to `PromptComposerExperiment` (the
    /// composer-module census of protected/known ids) and adds
    /// profile-level shape checks.
    public func validationErrors() -> [String] {
        var errors: [String] = []
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName.isEmpty {
            errors.append("profile name must be non-empty")
        } else if trimmedName.rangeOfCharacter(from: .whitespaces) != nil {
            errors.append("profile name must not contain whitespace (it names artifacts)")
        }
        errors.append(contentsOf: experiment.validationErrors())
        return errors
    }

    /// The composer-side override this profile resolves to.
    public var experiment: PromptComposerExperiment {
        PromptComposerExperiment(
            forceCompactPrompt: forceCompactPrompt,
            dropSectionIds: Set(dropSections ?? []),
            deferToolNames: Set(deferTools ?? []),
            compactLoadedResults: compactLoadedResults
        )
    }

    /// True when the profile changes nothing (the baseline shape).
    public var isBaseline: Bool { experiment.isNoOp }

    // MARK: - Provenance

    /// Resolved feature vector: one canonical `axis=value` string per
    /// active override, sorted — the report-embedded record of exactly
    /// what composition this run measured. Empty for the baseline.
    public var resolvedFeatureVector: [String] {
        var vector: [String] = []
        if let force = forceCompactPrompt {
            vector.append("compactPrompt=\(force ? "forced-on" : "forced-off")")
        }
        for id in Set(dropSections ?? []).sorted() {
            vector.append("dropSection=\(id)")
        }
        for tool in Set(deferTools ?? []).sorted() {
            vector.append("deferTool=\(tool)")
        }
        if compactLoadedResults == true {
            vector.append("compactLoadedResults=on")
        }
        return vector
    }

    /// Deterministic 16-hex-char hash over the canonical feature vector
    /// (NOT the JSON bytes, so formatting/description edits don't change
    /// identity — two profiles that compose identically hash identically).
    public var profileHash: String {
        let canonical = resolvedFeatureVector.joined(separator: "\n")
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in canonical.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(format: "%016llx", hash)
    }

    // MARK: - Loading

    /// Decode + validate a profile file. Throws with every validation
    /// problem listed (not just the first) so a hand-written profile
    /// gets one round-trip of feedback.
    public static func load(from url: URL) throws -> ExperimentProfile {
        let data = try Data(contentsOf: url)
        let profile = try JSONDecoder().decode(ExperimentProfile.self, from: data)
        let errors = profile.validationErrors()
        guard errors.isEmpty else {
            throw NSError(
                domain: "OsaurusEvals",
                code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "invalid experiment profile '\(profile.name)': "
                        + errors.joined(separator: "; ")
                ]
            )
        }
        return profile
    }
}
