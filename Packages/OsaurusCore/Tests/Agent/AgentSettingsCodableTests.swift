//
//  AgentSettingsCodableTests.swift
//  OsaurusCoreTests — Agent
//
//  Pins the Codable contract for the per-agent sub-agent settings (image
//  models, delegation permissions, spawn budgets). These fields back the
//  per-agent Sub-agents tab; a decode regression would silently drop a user's
//  model / permission / budget choices, so the round-trip + the back-compat
//  defaults are guarded here.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("AgentSettings per-agent sub-agent fields codable")
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
            SubagentCapabilityRegistry.sandboxReduce.id: "reducer-model",
            SubagentCapabilityRegistry.spawn.id: "spawn-model",
        ]

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AgentSettings.self, from: data)

        #expect(
            decoded.subagentModelOverrides[SubagentCapabilityRegistry.computerUse.id]
                == "vision-model"
        )
        #expect(
            decoded.subagentModelOverrides[SubagentCapabilityRegistry.sandboxReduce.id]
                == "reducer-model"
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

    @Test("a blank / whitespace model override entry is dropped on decode")
    func blankModelOverrideDroppedOnDecode() throws {
        // A cleared picker an older build may have persisted as "" (or a stray
        // whitespace value) must decode as "no override" so the per-agent stored
        // shape matches the global SubagentConfiguration normalization — never an
        // empty-string model id that would later resolve to a bogus override.
        let json = #"""
            {"dbEnabled":false,"subagentModelOverrides":{"computer_use":"   ","spawn":"real-model","sandbox_reduce":""}}
            """#
        let decoded = try JSONDecoder().decode(AgentSettings.self, from: Data(json.utf8))

        #expect(decoded.subagentModelOverrides[SubagentCapabilityRegistry.computerUse.id] == nil)
        #expect(decoded.subagentModelOverrides[SubagentCapabilityRegistry.sandboxReduce.id] == nil)
        #expect(
            decoded.subagentModelOverrides[SubagentCapabilityRegistry.spawn.id] == "real-model"
        )
        #expect(decoded.subagentModelOverrides.count == 1)
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
