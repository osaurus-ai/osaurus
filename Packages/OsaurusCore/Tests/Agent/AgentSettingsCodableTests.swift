//
//  AgentSettingsCodableTests.swift
//  OsaurusCoreTests — Agent
//
//  Pins the Codable contract for the per-agent subagent settings (image
//  models, delegation permissions, spawn budgets). These fields back the
//  per-agent Subagents tab; a decode regression would silently drop a user's
//  model / permission / budget choices, so the round-trip + the back-compat
//  defaults are guarded here.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("AgentSettings per-agent subagent fields codable")
struct AgentSettingsCodableTests {

    @Test("the per-agent image / permission / budget fields round-trip")
    func roundTripsNewFields() throws {
        var settings = AgentSettings.defaultDisabled
        settings.imageEnabled = true
        settings.spawnDelegationEnabled = true
        settings.spawnableAgentNames = ["Coder"]
        settings.imageGenerationModelId = "gen-model"
        settings.imageEditModelId = "edit-model"
        var perms = SubagentPermissionDefaults()
        perms.setPolicy(.alwaysAllow, for: SubagentCapabilityRegistry.image.id)
        perms.setPolicy(.deny, for: SubagentCapabilityRegistry.spawn.id)
        settings.subagentPermissions = perms
        settings.subagentBudgets = SubagentBudgets(
            maxDelegateTokens: 1024,
            maxDelegateTurns: 2,
            maxElapsedSeconds: 90
        )

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AgentSettings.self, from: data)

        #expect(decoded.imageGenerationModelId == "gen-model")
        #expect(decoded.imageEditModelId == "edit-model")
        #expect(
            decoded.subagentPermissions.policy(for: SubagentCapabilityRegistry.image.id)
                == .alwaysAllow
        )
        #expect(
            decoded.subagentPermissions.policy(for: SubagentCapabilityRegistry.spawn.id)
                == .deny
        )
        #expect(decoded.subagentBudgets.maxDelegateTokens == 1024)
        #expect(decoded.subagentBudgets.maxDelegateTurns == 2)
        #expect(decoded.subagentBudgets.maxElapsedSeconds == 90)
    }

    @Test("a nil image model survives the round-trip as nil (not an empty string)")
    func nilImageModelStaysNil() throws {
        var settings = AgentSettings.defaultDisabled
        settings.imageEnabled = true
        #expect(settings.imageGenerationModelId == nil)

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AgentSettings.self, from: data)

        #expect(decoded.imageGenerationModelId == nil)
        #expect(decoded.imageEditModelId == nil)
    }

    @Test("the per-agent subagent model overrides round-trip")
    func roundTripsModelOverrides() throws {
        var settings = AgentSettings.defaultDisabled
        settings.subagentModelOverrides = [
            SubagentCapabilityRegistry.computerUse.id: "vision-model",
            SubagentCapabilityRegistry.spawn.id: "spawn-model",
        ]

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AgentSettings.self, from: data)

        #expect(
            decoded.subagentModelOverrides[SubagentCapabilityRegistry.computerUse.id]
                == "vision-model"
        )
        #expect(
            decoded.subagentModelOverrides[SubagentCapabilityRegistry.spawn.id] == "spawn-model"
        )
    }

    @Test("legacy JSON without subagentModelOverrides decodes to an empty map")
    func backCompatModelOverrides() throws {
        // An older agent file that predates the per-capability model override.
        let json = #"{"dbEnabled":false,"computerUseEnabled":true}"#
        let decoded = try JSONDecoder().decode(AgentSettings.self, from: Data(json.utf8))

        #expect(decoded.subagentModelOverrides.isEmpty)
    }

    @Test("screenContextEnabled defaults to true when absent (back-compat)")
    func backCompatScreenContextDefaultsOn() throws {
        // Older agents (the feature was a global, default-off switch before)
        // have no `screenContextEnabled` key. It must decode to `true` so an
        // agent with Computer Use on gets ambient screen context by default,
        // matching the new "default on with Computer Use" contract.
        let json = #"{"dbEnabled":false,"computerUseEnabled":true}"#
        let decoded = try JSONDecoder().decode(AgentSettings.self, from: Data(json.utf8))

        #expect(decoded.screenContextEnabled == true)
        // The fresh-agent default also opts in.
        #expect(AgentSettings.defaultDisabled.screenContextEnabled == true)
    }

    @Test("screenContextEnabled round-trips both on and off")
    func roundTripsScreenContext() throws {
        var settings = AgentSettings.defaultDisabled
        settings.screenContextEnabled = false

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AgentSettings.self, from: data)
        #expect(decoded.screenContextEnabled == false)

        settings.screenContextEnabled = true
        let dataOn = try JSONEncoder().encode(settings)
        let decodedOn = try JSONDecoder().decode(AgentSettings.self, from: dataOn)
        #expect(decodedOn.screenContextEnabled == true)
    }

    @Test("a blank / whitespace model override entry is dropped on decode")
    func blankModelOverrideDroppedOnDecode() throws {
        // A cleared picker an older build may have persisted as "" (or a stray
        // whitespace value) must decode as "no override" so the per-agent stored
        // shape matches the global SubagentConfiguration normalization — never an
        // empty-string model id that would later resolve to a bogus override.
        let json = #"""
            {"dbEnabled":false,"subagentModelOverrides":{"computer_use":"   ","spawn":"real-model","image":""}}
            """#
        let decoded = try JSONDecoder().decode(AgentSettings.self, from: Data(json.utf8))

        #expect(decoded.subagentModelOverrides[SubagentCapabilityRegistry.computerUse.id] == nil)
        #expect(decoded.subagentModelOverrides[SubagentCapabilityRegistry.image.id] == nil)
        #expect(
            decoded.subagentModelOverrides[SubagentCapabilityRegistry.spawn.id] == "real-model"
        )
        #expect(decoded.subagentModelOverrides.count == 1)
    }

    @Test("the per-agent spawnable model pool + notes round-trip")
    func roundTripsSpawnableModelPool() throws {
        var settings = AgentSettings.defaultDisabled
        settings.spawnDelegationEnabled = true
        settings.spawnableModelNames = ["qwen3-4b-4bit", "openai/gpt-4o-mini"]
        settings.spawnableModelNotes = [
            "qwen3-4b-4bit": "Quick local edits",
            "openai/gpt-4o-mini": "Frontier reasoning",
        ]

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AgentSettings.self, from: data)

        #expect(decoded.spawnableModelNames == ["qwen3-4b-4bit", "openai/gpt-4o-mini"])
        #expect(decoded.spawnableModelNotes["qwen3-4b-4bit"] == "Quick local edits")
        #expect(decoded.spawnableModelNotes["openai/gpt-4o-mini"] == "Frontier reasoning")
    }

    @Test("legacy JSON without the spawnable model pool decodes to empty")
    func backCompatSpawnableModelPoolEmpty() throws {
        // An older agent file that predates the per-agent spawn_model pool.
        let json = #"{"dbEnabled":false,"spawnableAgentNames":["Coder"]}"#
        let decoded = try JSONDecoder().decode(AgentSettings.self, from: Data(json.utf8))

        #expect(decoded.spawnableModelNames.isEmpty)
        #expect(decoded.spawnableModelNotes.isEmpty)
        // The agent-name pool still decodes (proves the model keys are additive).
        #expect(decoded.spawnableAgentNames == ["Coder"])
    }

    @Test("legacy JSON without the new keys decodes to safe defaults")
    func backCompatDefaults() throws {
        // An older agent file that predates per-agent image / permission / budget.
        let json = #"{"dbEnabled":false,"imageEnabled":true}"#
        let decoded = try JSONDecoder().decode(AgentSettings.self, from: Data(json.utf8))

        #expect(decoded.imageGenerationModelId == nil)
        #expect(decoded.imageEditModelId == nil)
        // Missing permission map → every kind resolves to the safe `.ask` default.
        #expect(
            decoded.subagentPermissions.policy(for: SubagentCapabilityRegistry.image.id) == .ask
        )
        #expect(
            decoded.subagentPermissions.policy(for: SubagentCapabilityRegistry.spawn.id) == .ask
        )
        // Missing budgets → the struct defaults.
        #expect(decoded.subagentBudgets == SubagentBudgets())
    }
}
