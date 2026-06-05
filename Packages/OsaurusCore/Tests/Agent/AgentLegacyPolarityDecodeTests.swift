//
//  AgentLegacyPolarityDecodeTests.swift
//  OsaurusCoreTests
//
//  Guards the back-compat decode that migrates the legacy negative-polarity
//  `disableTools` / `disableMemory` keys onto the positive `toolsEnabled` /
//  `memoryEnabled` fields, plus the AutonomousExecConfig defaults (egress on,
//  dropped `commandTimeout` ignored).
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct AgentLegacyPolarityDecodeTests {

    private func encodeToDictionary(_ agent: Agent) throws -> [String: Any] {
        let data = try JSONEncoder().encode(agent)
        let obj = try JSONSerialization.jsonObject(with: data)
        return obj as! [String: Any]
    }

    private func decodeAgent(from dict: [String: Any]) throws -> Agent {
        let data = try JSONSerialization.data(withJSONObject: dict)
        return try JSONDecoder().decode(Agent.self, from: data)
    }

    @Test
    func legacyDisableKeys_migrateToPositivePolarity() throws {
        let agent = Agent(name: "Legacy", description: "d", systemPrompt: "p")
        var dict = try encodeToDictionary(agent)
        dict.removeValue(forKey: "toolsEnabled")
        dict.removeValue(forKey: "memoryEnabled")
        dict["disableTools"] = true
        dict["disableMemory"] = true

        let decoded = try decodeAgent(from: dict)
        #expect(decoded.toolsEnabled == false)
        #expect(decoded.memoryEnabled == false)
    }

    @Test
    func missingPolarityKeys_defaultToEnabled() throws {
        let agent = Agent(name: "NoFlags", description: "d", systemPrompt: "p")
        var dict = try encodeToDictionary(agent)
        dict.removeValue(forKey: "toolsEnabled")
        dict.removeValue(forKey: "memoryEnabled")
        // No legacy keys present either — both default to enabled.

        let decoded = try decodeAgent(from: dict)
        #expect(decoded.toolsEnabled == true)
        #expect(decoded.memoryEnabled == true)
    }

    @Test
    func newPolarityKeys_winOverLegacy() throws {
        let agent = Agent(
            name: "Both",
            description: "d",
            systemPrompt: "p",
            toolsEnabled: true,
            memoryEnabled: false
        )
        var dict = try encodeToDictionary(agent)
        // Inject contradictory legacy keys; the explicit new keys win.
        dict["disableTools"] = true  // would imply toolsEnabled == false
        dict["disableMemory"] = false  // would imply memoryEnabled == true

        let decoded = try decodeAgent(from: dict)
        #expect(decoded.toolsEnabled == true)
        #expect(decoded.memoryEnabled == false)
    }

    @Test
    func autonomousExec_ignoresLegacyCommandTimeout_egressDefaultsOn() throws {
        // Older agent JSON may still carry the removed `commandTimeout`
        // key; keyed decoding ignores it. sandboxNetworkEnabled defaults on
        // for a smooth first-run experience.
        let json = #"{"enabled": true, "commandTimeout": 42}"#
        let cfg = try JSONDecoder().decode(
            AutonomousExecConfig.self,
            from: Data(json.utf8)
        )
        #expect(cfg.enabled == true)
        #expect(cfg.sandboxNetworkEnabled == true)
        #expect(cfg.pluginCreate == true)
        #expect(cfg.allowHostSecretReads == false)
        #expect(cfg.maxCommandsPerTurn == 10)
        // Background jobs are opt-in: JSON without the key stays off.
        #expect(cfg.backgroundProcessEnabled == false)
    }

    @Test
    func autonomousExec_backgroundProcessEnabledRoundTrips() throws {
        let cfg = AutonomousExecConfig(enabled: true, backgroundProcessEnabled: true)
        let data = try JSONEncoder().encode(cfg)
        let decoded = try JSONDecoder().decode(AutonomousExecConfig.self, from: data)
        #expect(decoded.backgroundProcessEnabled == true)
    }
}
