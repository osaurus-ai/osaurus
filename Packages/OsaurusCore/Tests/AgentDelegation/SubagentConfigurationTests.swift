//
//  SubagentConfigurationTests.swift
//  osaurusTests
//
//  Covers the persisted settings contract used by cloud-to-local text
//  delegation and agent-triggered native image jobs.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Agent delegation configuration")
struct SubagentConfigurationTests {
    @Test("defaults are low RAM and ask-first")
    func defaultsAreSafe() {
        let config = SubagentConfiguration.default
        // Local handoff defaults ON so enabling spawn/image on a local-model
        // agent works without hunting for a second toggle; the RAM-safety
        // preflight (also on) guards it. Off-by-default lives per agent now.
        #expect(config.localTextDelegationEnabled == true)
        #expect(config.imageJobLoadPolicy == .agentSingleResidency)
        #expect(config.permissionDefaults.policy(for: "spawn") == .ask)
        #expect(config.permissionDefaults.policy(for: "image") == .ask)
        #expect(config.budgets.maxDelegateTokens == 2048)
        // 2 turns so a first tool-refusal envelope (text-only spawn) still
        // leaves the model one turn to produce its digest.
        #expect(config.budgets.maxDelegateTurns == 2)
        #expect(config.budgets.maxToolCalls == 0)
        #expect(config.budgets.maxElapsedSeconds == 120)
        // AppleScript keeps its model warm after a run by default for the
        // back-to-back automation latency win.
        #expect(config.appleScriptLoadPolicy == .keepWarmAfterJob)
    }

    @Test("AppleScript load policy round-trips and decodes leniently")
    func appleScriptLoadPolicyRoundTrips() throws {
        let config = SubagentConfiguration(appleScriptLoadPolicy: .singleResidency)
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(SubagentConfiguration.self, from: data)
        #expect(decoded.appleScriptLoadPolicy == .singleResidency)

        // Absent (legacy config) → the keep-warm default.
        let legacy = try JSONDecoder().decode(
            SubagentConfiguration.self,
            from: Data(#"{"localTextDelegationEnabled":true}"#.utf8)
        )
        #expect(legacy.appleScriptLoadPolicy == .keepWarmAfterJob)

        // An invalid/renamed raw value → the default, not a decode failure.
        #expect(AppleScriptLoadPolicy(storedValue: "garbage") == .keepWarmAfterJob)
        #expect(AppleScriptLoadPolicy(storedValue: "single_residency") == .singleResidency)
        #expect(AppleScriptLoadPolicy.singleResidency.keepWarmSeconds == 0)
        #expect(AppleScriptLoadPolicy.keepWarmAfterJob.keepWarmSeconds == 90)
    }

    @Test("mac_query read-model split defaults on, round-trips, and survives normalize")
    func appleScriptQueryResidentModelRoundTrips() throws {
        // Default ON: the read path skips the dedicated-model handoff.
        #expect(SubagentConfiguration.default.appleScriptQueryPrefersResidentModel == true)

        // An explicit opt-out survives encode → decode → normalized (the
        // store normalizes on every save+load; dropping it back to the init
        // default would make the toggle un-disableable).
        let config = SubagentConfiguration(appleScriptQueryPrefersResidentModel: false)
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(SubagentConfiguration.self, from: data)
        #expect(decoded.appleScriptQueryPrefersResidentModel == false)
        #expect(decoded.normalized.appleScriptQueryPrefersResidentModel == false)

        // Absent (legacy config) → on.
        let legacy = try JSONDecoder().decode(
            SubagentConfiguration.self,
            from: Data(#"{"localTextDelegationEnabled":true}"#.utf8)
        )
        #expect(legacy.appleScriptQueryPrefersResidentModel == true)
    }

    @Test("budget normalization clamps invalid values")
    func budgetNormalizationClampsInvalidValues() {
        let raw = SubagentBudgets(
            maxDelegateTokens: -10,
            maxDelegateTurns: 0,
            maxToolCalls: -1,
            maxElapsedSeconds: 0
        )

        #expect(raw.normalized.maxDelegateTokens == 256)
        #expect(raw.normalized.maxDelegateTurns == 1)
        #expect(raw.normalized.maxToolCalls == 0)
        #expect(raw.normalized.maxElapsedSeconds == 15)
    }

    @Test("budget normalization caps runaway values")
    func budgetNormalizationCapsRunawayValues() {
        let raw = SubagentBudgets(
            maxDelegateTokens: 1_000_000,
            maxDelegateTurns: 100,
            maxToolCalls: 100,
            maxElapsedSeconds: 100_000
        )

        #expect(raw.normalized.maxDelegateTokens == 32_768)
        #expect(raw.normalized.maxDelegateTurns == 8)
        #expect(raw.normalized.maxToolCalls == 32)
        #expect(raw.normalized.maxElapsedSeconds == 1_800)
    }

    @Test("configuration round trips stable raw values")
    func configurationRoundTrip() throws {
        let config = SubagentConfiguration(
            localTextDelegationEnabled: true,
            defaultImageGenerationModelId: "flux-schnell",
            defaultImageEditModelId: "qwen-image-edit",
            imageJobLoadPolicy: .manualPanelKeepsImageLoaded,
            permissionDefaults: SubagentPermissionDefaults(
                policies: ["spawn": .alwaysAllow, "image": .deny]
            ),
            budgets: SubagentBudgets(
                maxDelegateTokens: 4096,
                maxDelegateTurns: 2,
                maxToolCalls: 3,
                maxElapsedSeconds: 240
            )
        )

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(SubagentConfiguration.self, from: data)

        #expect(decoded == config)
        #expect(decoded.permissionDefaults.policy(for: "spawn").rawValue == "always_allow")
        #expect(decoded.permissionDefaults.policy(for: "image").rawValue == "deny")
        #expect(decoded.imageJobLoadPolicy.rawValue == "manual_panel_keeps_image_loaded")
    }

    @Test("legacy per-field permission keys migrate into the keyed map")
    func legacyPermissionKeysMigrate() throws {
        // Pre-map schema: top-level `spawn` / `image` keys. They must migrate to
        // the keyed map (and a single invalid raw value falls back to `.ask`
        // without nuking the rest — the BUG D lenience contract).
        let data = Data(
            """
            { "spawn": "always_allow", "image": "deny", "bogus": "nope" }
            """.utf8
        )

        let decoded = try JSONDecoder().decode(SubagentPermissionDefaults.self, from: data)

        #expect(decoded.policy(for: "spawn") == .alwaysAllow)
        #expect(decoded.policy(for: "image") == .deny)
        // Unknown kinds default to the safe `.ask`.
        #expect(decoded.policy(for: "applescript") == .ask)
    }

    @Test("a new kind's permission round-trips with no struct field")
    func newKindPermissionRoundTrips() throws {
        // The whole point of the keyed map: a future permissioned kind stores its
        // policy under its own id with no schema change here.
        let defaults = SubagentPermissionDefaults(
            policies: ["spawn": .deny, "applescript": .alwaysAllow]
        )

        let data = try JSONEncoder().encode(defaults)
        let decoded = try JSONDecoder().decode(SubagentPermissionDefaults.self, from: data)

        #expect(decoded == defaults)
        #expect(decoded.policy(for: "applescript") == .alwaysAllow)
        #expect(decoded.policy(for: "spawn") == .deny)
        #expect(decoded.policy(for: "image") == .ask)
    }

    @Test("normalization preserves a disabled RAM-safety preflight")
    func normalizationPreservesRamSafetyChoice() {
        // Regression: `.normalized` previously omitted ramSafetyPreflightEnabled, so
        // turning it OFF was silently reverted to the init default (true) on every
        // save/load (the store runs `.normalized` on both). It must survive.
        var config = SubagentConfiguration()
        config.ramSafetyPreflightEnabled = false

        #expect(config.normalized.ramSafetyPreflightEnabled == false)

        // Through a full encode round-trip too (decode then normalize).
        let data = try! JSONEncoder().encode(config)
        let decoded = try! JSONDecoder().decode(SubagentConfiguration.self, from: data)
        #expect(decoded.ramSafetyPreflightEnabled == false)
        #expect(decoded.normalized.ramSafetyPreflightEnabled == false)
    }

    @Test("normalization preserves spawnable agent names")
    func normalizationPreservesSpawnableNames() {
        var config = SubagentConfiguration()
        config.spawnableAgentNames = ["Researcher", "Coder"]

        #expect(config.normalized.spawnableAgentNames == ["Researcher", "Coder"])
        #expect(config.normalized.anyAgentSpawnable)
        #expect(config.normalized.isAgentSpawnable("researcher"))  // case-insensitive
    }

    @Test("subagent model overrides round-trip and drop blank entries")
    func modelOverridesRoundTripAndNormalize() throws {
        // `init` normalizes: it trims values and drops blank entries so a cleared
        // picker (empty string) round-trips as "no override", not an empty id.
        let config = SubagentConfiguration(
            subagentModelOverrides: [
                "spawn": "spawn-model",
                "computer_use": "  reducer-model  ",
                "image": "   ",
            ]
        )
        #expect(config.subagentModelOverrides["spawn"] == "spawn-model")
        #expect(config.subagentModelOverrides["computer_use"] == "reducer-model")
        #expect(config.subagentModelOverrides["image"] == nil)

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(SubagentConfiguration.self, from: data)
        #expect(decoded.subagentModelOverrides["spawn"] == "spawn-model")
        #expect(decoded.subagentModelOverrides["computer_use"] == "reducer-model")
        #expect(decoded.subagentModelOverrides["image"] == nil)
    }

    @Test("legacy config without subagentModelOverrides decodes to an empty map")
    func backCompatModelOverridesEmpty() throws {
        let data = Data(#"{"localTextDelegationEnabled":true}"#.utf8)
        let decoded = try JSONDecoder().decode(SubagentConfiguration.self, from: data)
        #expect(decoded.subagentModelOverrides.isEmpty)
    }

    @Test("spawnable model names + notes round-trip, trim/dedupe, and prune orphan notes")
    func spawnableModelPoolRoundTripAndNormalize() throws {
        // init normalizes: trim ids, drop blanks, de-dupe (exact, order-kept);
        // notes are trimmed, blank notes dropped, and any note whose id is no
        // longer in the pool is pruned (so removing a model drops its note).
        let config = SubagentConfiguration(
            spawnableModelNames: [
                "qwen3-4b-4bit",
                "  qwen3-4b-4bit  ",  // dup after trim → dropped
                "openai/gpt-4o-mini",
                "   ",  // blank → dropped
            ],
            spawnableModelNotes: [
                "qwen3-4b-4bit": "  Quick local edits  ",  // trimmed
                "openai/gpt-4o-mini": "   ",  // blank value → dropped
                "deleted-model": "orphan note",  // id not in pool → pruned
            ]
        )

        #expect(config.spawnableModelNames == ["qwen3-4b-4bit", "openai/gpt-4o-mini"])
        #expect(config.spawnableModelNotes == ["qwen3-4b-4bit": "Quick local edits"])

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(SubagentConfiguration.self, from: data)
        #expect(decoded == config)
        #expect(decoded.spawnableModelNames == ["qwen3-4b-4bit", "openai/gpt-4o-mini"])
        #expect(decoded.spawnableModelNotes == ["qwen3-4b-4bit": "Quick local edits"])
    }

    @Test("legacy config without the spawnable model pool decodes to empty")
    func backCompatModelPoolEmpty() throws {
        let data = Data(#"{"localTextDelegationEnabled":true}"#.utf8)
        let decoded = try JSONDecoder().decode(SubagentConfiguration.self, from: data)
        #expect(decoded.spawnableModelNames.isEmpty)
        #expect(decoded.spawnableModelNotes.isEmpty)
        #expect(!decoded.anyModelSpawnable)
    }

    @Test("model-pool helpers: exact/trimmed membership, anySpawnable, and note lookup")
    func modelPoolHelpers() {
        let config = SubagentConfiguration(
            spawnableModelNames: ["qwen3-4b-4bit"],
            spawnableModelNotes: ["qwen3-4b-4bit": "Quick local edits"]
        )
        #expect(config.anyModelSpawnable)
        // Exact match, trimmed (model ids are canonical — NOT case-insensitive
        // like agent names).
        #expect(config.isModelSpawnable("qwen3-4b-4bit"))
        #expect(config.isModelSpawnable("  qwen3-4b-4bit  "))
        #expect(!config.isModelSpawnable("Qwen3-4B-4bit"))
        #expect(!config.isModelSpawnable("other-model"))
        // Note lookup is trimmed; absent ids return nil.
        #expect(config.modelNote("qwen3-4b-4bit") == "Quick local edits")
        #expect(config.modelNote("other-model") == nil)
    }
}
