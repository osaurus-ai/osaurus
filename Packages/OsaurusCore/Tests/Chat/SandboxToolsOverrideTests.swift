//
//  SandboxToolsOverrideTests.swift
//  OsaurusCoreTests
//
//  Pins `SystemPromptComposer.resolveEffectiveToolsOff` — the rule that
//  decides whether tools are suppressed for a compose.
//
//  The per-agent "Tools" toggle (Configure tab) is a chat-only kill-switch.
//  When the agent is in sandbox mode (Autonomous Execution on, which is what
//  resolves the execution mode to `.sandbox`), that toggle is overridden so
//  the sandbox tool surface stays exposed — the user already granted
//  execution. Two signals stay absolute and are NOT overridable: the
//  session-global "Disable tools" switch and the small-context auto-disable.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct SandboxToolsOverrideTests {

    private let sandbox = ExecutionMode.sandbox(hostRead: nil)

    @Test
    func perAgentToggleOff_inSandbox_keepsToolsOn() {
        // The reported case: Tools toggle off, sandbox + autonomous on.
        let off = SystemPromptComposer.resolveEffectiveToolsOff(
            toolsDisabled: true,
            globalToolsDisabled: false,
            sizeClassDisablesTools: false,
            executionMode: sandbox
        )
        #expect(off == false)
    }

    @Test
    func perAgentToggleOff_outsideSandbox_stillDisablesTools() {
        // Non-sandbox modes keep the per-agent toggle as a real kill-switch.
        let off = SystemPromptComposer.resolveEffectiveToolsOff(
            toolsDisabled: true,
            globalToolsDisabled: false,
            sizeClassDisablesTools: false,
            executionMode: .none
        )
        #expect(off == true)
    }

    @Test
    func globalSwitch_isAbsolute_evenInSandbox() {
        let off = SystemPromptComposer.resolveEffectiveToolsOff(
            toolsDisabled: true,
            globalToolsDisabled: true,
            sizeClassDisablesTools: false,
            executionMode: sandbox
        )
        #expect(off == true)
    }

    @Test
    func sizeClassDisable_isAbsolute_evenInSandbox() {
        let off = SystemPromptComposer.resolveEffectiveToolsOff(
            toolsDisabled: false,
            globalToolsDisabled: false,
            sizeClassDisablesTools: true,
            executionMode: sandbox
        )
        #expect(off == true)
    }

    @Test
    func allEnabled_keepsToolsOn() {
        let off = SystemPromptComposer.resolveEffectiveToolsOff(
            toolsDisabled: false,
            globalToolsDisabled: false,
            sizeClassDisablesTools: false,
            executionMode: sandbox
        )
        #expect(off == false)
    }

    /// With the per-agent Tools toggle off, the sandbox override exposes only
    /// sandbox primitives + agent-loop tools — NOT the capability-discovery
    /// gateway. Otherwise a "chat-only + sandbox" agent could discover and load
    /// arbitrary enabled plugins (Search, Calendar, …), which is wider than the
    /// toggle's chat-only intent.
    @Test
    @MainActor
    func toolsToggleOff_inSandbox_dropsCapabilityDiscoveryGateway() {
        ConfigurationDomainBootstrap.registerBuiltIns()
        let snapshot = AgentConfigSnapshot(
            agentId: UUID(),
            toolsDisabled: true,  // per-agent toggle off
            memoryDisabled: false,
            autonomousConfig: nil,
            toolMode: .auto,
            model: nil,
            manualToolNames: nil,
            systemPrompt: "",
            dbEnabled: false
        )
        // `toolsDisabled: false` here mirrors the resolved `effectiveToolsOff`
        // after the sandbox override flips it; the snapshot still records the
        // per-agent toggle as off, which is what triggers the restriction.
        let names = Set(
            SystemPromptComposer.resolveTools(
                snapshot: snapshot,
                executionMode: .sandbox(hostRead: nil),
                toolsDisabled: false
            ).map { $0.function.name }
        )
        #expect(!names.contains("capabilities_discover"))
        #expect(!names.contains("capabilities_load"))
        // The agent-loop tools survive so the sandbox loop can still run.
        #expect(names.contains("complete"))
    }

    /// Contrast: with the toggle ON (snapshot.toolsDisabled false), the full
    /// surface — including the discovery gateway — stays exposed in sandbox.
    @Test
    @MainActor
    func toolsToggleOn_inSandbox_keepsCapabilityDiscoveryGateway() {
        ConfigurationDomainBootstrap.registerBuiltIns()
        let snapshot = AgentConfigSnapshot(
            agentId: UUID(),
            toolsDisabled: false,  // per-agent toggle on
            memoryDisabled: false,
            autonomousConfig: nil,
            toolMode: .auto,
            model: nil,
            manualToolNames: nil,
            systemPrompt: "",
            dbEnabled: false
        )
        let names = Set(
            SystemPromptComposer.resolveTools(
                snapshot: snapshot,
                executionMode: .sandbox(hostRead: nil),
                toolsDisabled: false
            ).map { $0.function.name }
        )
        #expect(names.contains("capabilities_discover"))
        #expect(names.contains("capabilities_load"))
    }
}
