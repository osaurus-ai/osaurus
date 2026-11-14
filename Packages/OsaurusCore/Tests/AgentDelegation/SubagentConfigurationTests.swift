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
        // Local spawn is Always Allow out of the box: workers run on the
        // user's own agents, which carry their own permission cards.
        #expect(config.permissionDefaults.policy(for: "spawn") == .alwaysAllow)
        #expect(config.permissionDefaults.policy(for: "image") == .ask)
        #expect(
            config.permissionDefaults.policy(for: SubagentPermissionDefaults.workspaceSpawnKindId)
                == .ask
        )
        // Sized so a worker can finish a real task (users reported the old
        // 2048-token / 2-turn / 120 s defaults ended runs too early).
        #expect(config.budgets.maxDelegateTokens == 8192)
        #expect(config.budgets.maxDelegateTurns == 24)
        #expect(config.budgets.maxElapsedSeconds == 900)
        #expect(config.budgets.maxParallelSpawns == 3)
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
            maxElapsedSeconds: 0,
            maxParallelSpawns: 0
        )

        #expect(raw.normalized.maxDelegateTokens == 256)
        #expect(raw.normalized.maxDelegateTurns == 1)
        #expect(raw.normalized.maxElapsedSeconds == 15)
        #expect(raw.normalized.maxParallelSpawns == 1)
    }

    @Test("budget normalization caps runaway values")
    func budgetNormalizationCapsRunawayValues() {
        let raw = SubagentBudgets(
            maxDelegateTokens: 1_000_000,
            maxDelegateTurns: 1_000,
            maxElapsedSeconds: 100_000,
            maxParallelSpawns: 100
        )

        #expect(raw.normalized.maxDelegateTokens == 65_536)
        #expect(raw.normalized.maxDelegateTurns == 100)
        #expect(raw.normalized.maxElapsedSeconds == 3_600)
        #expect(raw.normalized.maxParallelSpawns == 32)
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
                maxElapsedSeconds: 240,
                maxParallelSpawns: 4
            )
        )

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(SubagentConfiguration.self, from: data)

        #expect(decoded == config)
        #expect(decoded.permissionDefaults.policy(for: "spawn").rawValue == "always_allow")
        #expect(decoded.permissionDefaults.policy(for: "image").rawValue == "deny")
        #expect(decoded.imageJobLoadPolicy.rawValue == "manual_panel_keeps_image_loaded")
        #expect(decoded.budgets.maxParallelSpawns == 4)
    }

    @Test("legacy budgets without maxParallelSpawns decode to the bounded default")
    func legacyBudgetsDecodeParallelDefault() throws {
        let decoded = try JSONDecoder().decode(
            SubagentBudgets.self,
            from: Data(
                """
                {
                  "maxDelegateTokens": 1024,
                  "maxDelegateTurns": 1,
                  "maxToolCalls": 2,
                  "maxElapsedSeconds": 60
                }
                """.utf8
            )
        )
        #expect(decoded.maxDelegateTokens == 1024)
        #expect(decoded.maxParallelSpawns == 3)
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

    @Test("normalization preserves stable spawnable agent IDs")
    func normalizationPreservesSpawnableIDs() {
        let researcherID = UUID(uuidString: "20000000-0000-4000-8000-000000000001")!
        let coderID = UUID(uuidString: "20000000-0000-4000-8000-000000000002")!
        var config = SubagentConfiguration()
        config.spawnableAgentIDs = [researcherID, coderID, researcherID]

        #expect(config.normalized.spawnableAgentIDs == [researcherID, coderID])
        #expect(config.normalized.anyAgentSpawnable)
        #expect(config.normalized.isAgentSpawnable(researcherID))
        #expect(!config.normalized.isAgentSpawnable(UUID()))
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

    @Test("legacy spawnable model pool + worker tool-access keys are ignored on decode")
    func legacyModelPoolKeysIgnored() throws {
        // `spawn_model` was removed; older files still carry its pool. They
        // decode cleanly and the keys are not written back.
        let data = Data(
            #"""
            {"localTextDelegationEnabled":true,
             "spawnableModelNames":["qwen3-4b-4bit"],
             "spawnableModelNotes":{"qwen3-4b-4bit":"Quick local edits"},
             "spawnToolAccess":"readOnly",
             "budgets":{"maxDelegateTokens":4096,"maxToolCalls":6}}
            """#.utf8)
        let decoded = try JSONDecoder().decode(SubagentConfiguration.self, from: data)
        #expect(decoded.localTextDelegationEnabled == true)
        #expect(decoded.budgets.maxDelegateTokens == 4096)
        let reencoded = String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self)
        #expect(!reencoded.contains("spawnableModelNames"))
        #expect(!reencoded.contains("spawnToolAccess"))
        #expect(!reencoded.contains("maxToolCalls"))
    }

    // MARK: - Workspace agents: auto-join, tombstones, prune, per-workspace switch

    /// `WorkspaceAgentRef` keeps only real 42-char `0x…` addresses; pad a
    /// short label into one so fixtures stay readable.
    private static func ref(_ workspace: String, _ label: String) -> WorkspaceAgentRef {
        let hex = label.lowercased().filter(\.isHexDigit)
        let address = "0x" + String(repeating: "0", count: max(0, 40 - hex.count)) + hex
        return WorkspaceAgentRef(workspaceId: workspace, agentAddress: address)
    }

    @Test("roster refs auto-join the pool; user removals stay removed across re-shares")
    func workspaceAutoJoinRespectsTombstones() {
        let alice = Self.ref("ws-1", "0xaaa1")
        let bob = Self.ref("ws-1", "0xbbb2")
        var config = SubagentConfiguration()

        config = config.reconcilingWorkspaceAgents(rosterRefs: [alice, bob], loadedWorkspaceIds: ["ws-1"])
        #expect(Set(config.spawnableWorkspaceAgents) == [alice, bob])

        // The user removes Bob in the editor → tombstoned, and a later roster
        // tick that still lists him must NOT bring him back.
        config.removeWorkspaceAgent(bob)
        #expect(config.spawnableWorkspaceAgents == [alice])
        #expect(config.removedWorkspaceAgents == [bob])
        config = config.reconcilingWorkspaceAgents(rosterRefs: [alice, bob], loadedWorkspaceIds: ["ws-1"])
        #expect(config.spawnableWorkspaceAgents == [alice])

        // Re-adding clears the tombstone.
        config.addWorkspaceAgent(bob)
        #expect(config.removedWorkspaceAgents.isEmpty)
        #expect(Set(config.spawnableWorkspaceAgents) == [alice, bob])
    }

    @Test("unshared agents and left workspaces prune; unloaded workspaces are trusted")
    func workspacePruneOnlyForKnownWorkspaces() {
        let alice = Self.ref("ws-1", "0xaaa1")
        let bob = Self.ref("ws-1", "0xbbb2")
        let carol = Self.ref("ws-2", "0xccc3")
        var config = SubagentConfiguration(spawnableWorkspaceAgents: [alice, bob, carol])
        config.removeWorkspaceAgent(bob)

        // ws-2 has not loaded (cold start): Carol is kept. ws-1 loaded and
        // no longer lists Bob: his pool entry AND his tombstone go.
        config = config.reconcilingWorkspaceAgents(rosterRefs: [alice], loadedWorkspaceIds: ["ws-1"])
        #expect(Set(config.spawnableWorkspaceAgents) == [alice, carol])
        #expect(config.removedWorkspaceAgents.isEmpty)

        // Leaving ws-2 (its id is reported as known with no roster refs)
        // drops Carol.
        config = config.reconcilingWorkspaceAgents(rosterRefs: [alice], loadedWorkspaceIds: ["ws-1", "ws-2"])
        #expect(config.spawnableWorkspaceAgents == [alice])
    }

    @Test("per-workspace auto-join off prunes that workspace and stops joining")
    func workspaceAutoJoinSwitch() {
        let alice = Self.ref("ws-1", "0xaaa1")
        let carol = Self.ref("ws-2", "0xccc3")
        var config = SubagentConfiguration()
        config = config.reconcilingWorkspaceAgents(
            rosterRefs: [alice, carol], loadedWorkspaceIds: ["ws-1", "ws-2"])
        #expect(Set(config.spawnableWorkspaceAgents) == [alice, carol])

        config.setWorkspaceAutoJoin(false, workspaceId: "WS-2")
        #expect(!config.workspaceAutoJoinEnabled("ws-2"))
        config = config.reconcilingWorkspaceAgents(
            rosterRefs: [alice, carol], loadedWorkspaceIds: ["ws-1", "ws-2"])
        #expect(config.spawnableWorkspaceAgents == [alice])

        config.setWorkspaceAutoJoin(true, workspaceId: "ws-2")
        config = config.reconcilingWorkspaceAgents(
            rosterRefs: [alice, carol], loadedWorkspaceIds: ["ws-1", "ws-2"])
        #expect(Set(config.spawnableWorkspaceAgents) == [alice, carol])
    }
}
