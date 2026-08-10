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

}
