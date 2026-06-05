//
//  BridgePluginCreateGateTests.swift
//  OsaurusCoreTests
//
//  Pins the plugin-create gate that both the in-app tool and the host
//  bridge (`HostAPIBridgeServer.handlePlugin`) consume: creation requires
//  autonomous execution ENABLED *and* `pluginCreate` on. Because
//  `pluginCreate` defaults true, checking it alone would let an
//  autonomous-disabled agent create plugins through the bridge.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct BridgePluginCreateGateTests {

    private func snapshot(with config: AutonomousExecConfig?) -> AgentConfigSnapshot {
        AgentConfigSnapshot(
            agentId: UUID(),
            toolsDisabled: false,
            memoryDisabled: false,
            autonomousConfig: config,
            toolMode: .auto,
            model: nil,
            manualToolNames: nil,
            systemPrompt: "",
            dbEnabled: false
        )
    }

    @Test
    func refusesWhenAutonomousDisabledEvenIfPluginCreateOn() {
        let s = snapshot(with: AutonomousExecConfig(enabled: false, pluginCreate: true))
        #expect(s.canCreatePlugins == false)
    }

    @Test
    func refusesWhenPluginCreateOff() {
        let s = snapshot(with: AutonomousExecConfig(enabled: true, pluginCreate: false))
        #expect(s.canCreatePlugins == false)
    }

    @Test
    func refusesWhenNoAutonomousConfig() {
        let s = snapshot(with: nil)
        #expect(s.canCreatePlugins == false)
    }

    @Test
    func allowsWhenBothEnabled() {
        let s = snapshot(with: AutonomousExecConfig(enabled: true, pluginCreate: true))
        #expect(s.canCreatePlugins == true)
    }
}
