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
}
