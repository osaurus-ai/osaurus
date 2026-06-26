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
