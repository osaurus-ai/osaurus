//
//  SubagentScopeReasoningTests.swift
//  OsaurusCore
//
//  Pins the delegated-reasoning parity contract: the parent turn's explicit
//  Thinking choice scopes to the parent's own model. A delegated run on a
//  DIFFERENT model resolves its own persisted options + bundle default
//  (ChatEngine's agent-options path) instead of inheriting the parent's
//  toggle — forwarding it verbatim forced a Thinking-off parent onto a
//  Thinking-on child (reported live 2026-09-01).
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct SubagentScopeReasoningTests {
    @Test func sameModelEffortIsFrozenAndDifferentModelKeepsItsOwnChoice() {
        for effort in ["none", "low", "medium", "xhigh"] {
            let frozen = SubagentScope(
                sessionId: "s",
                toolCallId: "t",
                agentId: Agent.defaultId,
                parentModelName: "publisher/bonsai",
                reasoningEffort: effort
            )
            #expect(frozen.reasoningEffort(forDelegatedModel: "Publisher/Bonsai") == effort)
            #expect(frozen.reasoningEffort(forDelegatedModel: "publisher/gemma") == nil)
            #expect(frozen.reasoningEffort(forDelegatedModel: nil) == nil)
        }
    }

    private func scope(
        parentModel: String?,
        enableThinking: Bool?
    ) -> SubagentScope {
        SubagentScope(
            sessionId: "s",
            toolCallId: "t",
            agentId: Agent.defaultId,
            parentModelName: parentModel,
            enableThinking: enableThinking
        )
    }

    @Test func sameModelInheritsParentChoice() {
        let s = scope(parentModel: "Qwen3.8 27B JANG_4D", enableThinking: false)
        #expect(s.enableThinking(forDelegatedModel: "Qwen3.8 27B JANG_4D") == false)
        // Case-insensitive: resolved names can differ in casing.
        #expect(s.enableThinking(forDelegatedModel: "qwen3.8 27b jang_4d") == false)
    }

    @Test func differentModelResolvesItsOwnDefaults() {
        let s = scope(parentModel: "Qwen3.8 27B JANG_4D", enableThinking: false)
        #expect(s.enableThinking(forDelegatedModel: "Ling 3.0 tiny JANG_6M") == nil)

        let on = scope(parentModel: "Qwen3.8 27B JANG_4D", enableThinking: true)
        #expect(on.enableThinking(forDelegatedModel: "Ling 3.0 tiny JANG_6M") == nil)
    }

    @Test func missingParentOrChildMeansNoInheritance() {
        #expect(
            scope(parentModel: nil, enableThinking: false)
                .enableThinking(forDelegatedModel: "any") == nil)
        #expect(
            scope(parentModel: "m", enableThinking: false)
                .enableThinking(forDelegatedModel: nil) == nil)
    }

    @Test func unsetParentChoiceStaysUnset() {
        let s = scope(parentModel: "m", enableThinking: nil)
        #expect(s.enableThinking(forDelegatedModel: "m") == nil)
    }

    @Test func sameModelSpeculationAndKeepCacheInRAMAreScopedToParentModel() {
        let s = SubagentScope(
            sessionId: "s",
            toolCallId: "t",
            agentId: Agent.defaultId,
            parentModelName: "OsaurusAI/ERNIE-5.5-Flash",
            speculativeDecoding: false,
            keepCacheInRAM: true
        )
        #expect(s.speculativeDecoding(forDelegatedModel: "osaurusai/ernie-5.5-flash") == false)
        #expect(s.keepCacheInRAM(forDelegatedModel: "osaurusai/ernie-5.5-flash") == true)
        #expect(s.speculativeDecoding(forDelegatedModel: "OsaurusAI/Inkling-2-Mini") == nil)
        #expect(s.keepCacheInRAM(forDelegatedModel: "OsaurusAI/Inkling-2-Mini") == nil)
    }

    @Test func chatTurnGenerationControlsEffectiveEnableThinkingRespectsPrecedence() {
        var controls = ChatTurnGenerationControls.capture(activeModelOptions: ["disableThinking": .bool(true)])
        #expect(controls.effectiveEnableThinking == false)
        controls.agentSettings = AgentGenerationSettings(enableThinking: true)
        #expect(controls.effectiveEnableThinking == true)
        controls.overrides.enableThinking = false
        #expect(controls.effectiveEnableThinking == false)
    }
}
