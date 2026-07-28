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
        let coderID = UUID(uuidString: "10000000-0000-4000-8000-000000000001")!
        var settings = AgentSettings.defaultDisabled
        settings.imageEnabled = true
        settings.spawnDelegationEnabled = true
        settings.spawnableAgentIDs = [coderID]
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
        #expect(decoded.spawnableAgentIDs == [coderID])
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

    @Test("disabling Spawn preserves the custom agent's configured policy")
    func disabledSpawnPreservesConfiguredPolicy() throws {
        let researcherID = UUID(uuidString: "10000000-0000-4000-8000-000000000002")!
        let workerID = UUID(uuidString: "10000000-0000-4000-8000-000000000003")!
        var settings = AgentSettings.defaultDisabled
        settings.spawnDelegationEnabled = false
        settings.spawnableAgentIDs = [researcherID, workerID]
        settings.spawnableModelNames = ["local/fast-helper", "openai/frontier-helper"]
        settings.spawnableModelNotes = [
            "local/fast-helper": "Fast local batches",
            "openai/frontier-helper": "Difficult reasoning",
        ]
        settings.subagentModelOverrides = [
            SubagentCapabilityRegistry.spawn.id: "local/override-helper"
        ]
        var permissions = SubagentPermissionDefaults()
        permissions.setPolicy(.alwaysAllow, for: SubagentCapabilityRegistry.spawn.id)
        settings.subagentPermissions = permissions
        settings.subagentBudgets = SubagentBudgets(
            maxDelegateTokens: 8192,
            maxDelegateTurns: 5,
            maxToolCalls: 8,
            maxElapsedSeconds: 600,
            maxParallelSpawns: 4
        )
        settings.spawnToolAccess = .readOnly

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AgentSettings.self, from: data)

        #expect(decoded.spawnDelegationEnabled == false)
        #expect(decoded.spawnableAgentIDs == [researcherID, workerID])
        #expect(
            decoded.spawnableModelNames
                == ["local/fast-helper", "openai/frontier-helper"]
        )
        #expect(decoded.spawnableModelNotes["local/fast-helper"] == "Fast local batches")
        #expect(decoded.spawnableModelNotes["openai/frontier-helper"] == "Difficult reasoning")
        #expect(
            decoded.subagentModelOverrides[SubagentCapabilityRegistry.spawn.id]
                == "local/override-helper"
        )
        #expect(
            decoded.subagentPermissions.policy(for: SubagentCapabilityRegistry.spawn.id)
                == .alwaysAllow
        )
        #expect(decoded.subagentBudgets.maxDelegateTokens == 8192)
        #expect(decoded.subagentBudgets.maxDelegateTurns == 5)
        #expect(decoded.subagentBudgets.maxToolCalls == 8)
        #expect(decoded.subagentBudgets.maxElapsedSeconds == 600)
        #expect(decoded.subagentBudgets.maxParallelSpawns == 4)
        #expect(decoded.spawnToolAccess == .readOnly)
    }

    @Test("legacy JSON without the spawnable model pool decodes to empty")
    func backCompatSpawnableModelPoolEmpty() throws {
        // An older agent file that predates the per-agent spawn_model pool.
        let json = #"{"dbEnabled":false,"spawnableAgentNames":["Coder"]}"#
        let decoded = try JSONDecoder().decode(AgentSettings.self, from: Data(json.utf8))

        #expect(decoded.spawnableModelNames.isEmpty)
        #expect(decoded.spawnableModelNotes.isEmpty)
        // The legacy name pool is decode-only until the full catalog is
        // available for deterministic UUID migration.
        #expect(decoded.spawnableAgentIDs.isEmpty)
        #expect(decoded.legacySpawnableAgentNames == ["Coder"])
    }

    @Test("legacy agent names migrate uniquely and ambiguous collisions fail closed")
    func legacyAgentNameMigrationIsDeterministic() throws {
        let helperID = UUID(uuidString: "10000000-0000-4000-8000-000000000004")!
        let upperID = UUID(uuidString: "10000000-0000-4000-8000-000000000005")!
        let lowerID = UUID(uuidString: "10000000-0000-4000-8000-000000000006")!
        let json = #"{"dbEnabled":false,"spawnableAgentNames":["Coder","Helper","missing"]}"#
        let decoded = try JSONDecoder().decode(AgentSettings.self, from: Data(json.utf8))
        let migrated = decoded.migratingLegacySpawnableAgents(
            using: [
                Agent(id: helperID, name: "Coder"),
                Agent(id: upperID, name: "Helper"),
                Agent(id: lowerID, name: "helper"),
            ]
        )

        #expect(migrated.spawnableAgentIDs == [helperID])
        #expect(migrated.legacySpawnableAgentNames.isEmpty)
        let encoded = try JSONEncoder().encode(migrated)
        let object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        #expect(object["spawnableAgentNames"] == nil)
        #expect((object["spawnableAgentIDs"] as? [String]) == [helperID.uuidString])
    }

    @Test("case-colliding agents retain distinct models and tool grants by UUID")
    func caseCollidingAgentIdentitySurvivesRoundTrip() throws {
        let upperID = UUID(uuidString: "10000000-0000-4000-8000-000000000007")!
        let lowerID = UUID(uuidString: "10000000-0000-4000-8000-000000000008")!
        let upper = Agent(
            id: upperID,
            name: "Helper",
            defaultModel: "local/helper-read",
            toolSelectionMode: .manual,
            manualToolNames: ["file_read"]
        )
        let lower = Agent(
            id: lowerID,
            name: "helper",
            defaultModel: "local/helper-write",
            toolSelectionMode: .manual,
            manualToolNames: ["file_write"]
        )

        let data = try JSONEncoder().encode([upper, lower])
        let decoded = try JSONDecoder().decode([Agent].self, from: data)
        let byID = Dictionary(uniqueKeysWithValues: decoded.map { ($0.id, $0) })

        #expect(byID[upperID]?.name == "Helper")
        #expect(byID[upperID]?.defaultModel == "local/helper-read")
        #expect(byID[upperID]?.manualToolNames == ["file_read"])
        #expect(byID[lowerID]?.name == "helper")
        #expect(byID[lowerID]?.defaultModel == "local/helper-write")
        #expect(byID[lowerID]?.manualToolNames == ["file_write"])
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
